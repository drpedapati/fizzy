require "base64"
require "net/http"

class Sessions::MicrosoftOauthsController < ApplicationController
  class OAuthError < StandardError; end

  disallow_account_scope
  require_unauthenticated_access

  layout "public"

  def show
    ensure_configured!

    session[:microsoft_oauth_state] = state = SecureRandom.hex(24)
    session[:microsoft_oauth_nonce] = nonce = SecureRandom.hex(24)

    redirect_to authorization_url(state: state, nonce: nonce), allow_other_host: true
  rescue OAuthError => error
    sign_in_failed(error)
  end

  def callback
    ensure_configured!
    ensure_state_matches!

    claims = claims_from_token_exchange
    ensure_nonce_matches!(claims)
    ensure_tenant_matches!(claims)

    identity = Identity.find_or_create_by!(email_address: email_address_from(claims))
    start_new_session_for identity

    redirect_to after_microsoft_sign_in_url(identity)
  rescue OAuthError => error
    sign_in_failed(error)
  end

  private
    def ensure_configured!
      unless microsoft_oauth_configured?
        raise OAuthError, "Microsoft OAuth is not configured"
      end
    end

    def authorization_url(state:, nonce:)
      uri = URI("https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/authorize")
      uri.query = {
        client_id: client_id,
        response_type: "code",
        redirect_uri: redirect_uri,
        response_mode: "query",
        scope: "openid email profile",
        state: state,
        nonce: nonce
      }.to_query
      uri.to_s
    end

    def claims_from_token_exchange
      if params[:error].present?
        raise OAuthError, "Microsoft returned #{params[:error]}: #{params[:error_description]}"
      end

      token_response = exchange_code_for_token
      decode_id_token token_response.fetch("id_token")
    rescue KeyError
      raise OAuthError, "Microsoft token response did not include an id_token"
    end

    def exchange_code_for_token
      response = Net::HTTP.post_form token_uri, {
        client_id: client_id,
        client_secret: client_secret,
        code: params.expect(:code),
        grant_type: "authorization_code",
        redirect_uri: redirect_uri,
        scope: "openid email profile"
      }

      json = JSON.parse(response.body)
      return json if response.is_a?(Net::HTTPSuccess)

      raise OAuthError, "Microsoft token exchange failed: #{json["error_description"] || json["error"] || response.code}"
    rescue JSON::ParserError
      raise OAuthError, "Microsoft token exchange returned an invalid response"
    end

    def decode_id_token(id_token)
      _header, payload, _signature = id_token.to_s.split(".")
      raise OAuthError, "Microsoft returned an invalid id_token" if payload.blank?

      JSON.parse Base64.urlsafe_decode64(padded_base64(payload))
    rescue JSON::ParserError, ArgumentError
      raise OAuthError, "Microsoft returned an unreadable id_token"
    end

    def padded_base64(value)
      value + ("=" * ((4 - value.length % 4) % 4))
    end

    def ensure_state_matches!
      expected_state = session.delete(:microsoft_oauth_state)
      unless expected_state.present? && ActiveSupport::SecurityUtils.secure_compare(expected_state, params[:state].to_s)
        raise OAuthError, "Microsoft OAuth state did not match"
      end
    end

    def ensure_nonce_matches!(claims)
      expected_nonce = session.delete(:microsoft_oauth_nonce)
      unless expected_nonce.present? && ActiveSupport::SecurityUtils.secure_compare(expected_nonce, claims["nonce"].to_s)
        raise OAuthError, "Microsoft OAuth nonce did not match"
      end
    end

    def ensure_tenant_matches!(claims)
      unless ActiveSupport::SecurityUtils.secure_compare(tenant_id, claims["tid"].to_s)
        raise OAuthError, "Microsoft OAuth tenant did not match"
      end
    end

    def email_address_from(claims)
      claims.values_at("email", "preferred_username", "upn").find(&:present?).tap do |email_address|
        raise OAuthError, "Microsoft did not return an email address" if email_address.blank?
      end
    end

    def after_microsoft_sign_in_url(identity)
      if identity.users.exists?
        after_authentication_url
      else
        new_signup_completion_path
      end
    end

    def sign_in_failed(error)
      Rails.logger.warn "Microsoft OAuth sign-in failed: #{error.message}"
      redirect_to new_session_path, alert: "CCHMC sign-in didn't work. Please try again."
    end

    def token_uri
      URI("https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/token")
    end

    def redirect_uri
      ENV.fetch("MICROSOFT_REDIRECT_URI") { callback_session_microsoft_oauth_url(script_name: nil) }
    end

    def tenant_id
      ENV.fetch("MICROSOFT_TENANT_ID")
    end

    def client_id
      ENV.fetch("MICROSOFT_CLIENT_ID")
    end

    def client_secret
      ENV.fetch("MICROSOFT_CLIENT_SECRET")
    end
end

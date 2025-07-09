# frozen_string_literal: true

require_relative 'common_patch_behavior'

module OutboundHTTPLogger
  module Patches
    module FaradayPatch
      extend CommonPatchBehavior::ClassMethods

      def self.apply!
        apply_patch_safely!(Faraday, Faraday::Connection, ConnectionMethods, 'Faraday')
      end

      module ConnectionMethods
        include CommonPatchBehavior

        def run_request(method, url, body, headers, &)
          # Build the full URL first
          full_url = build_url(url)

          # Use common logging behavior
          log_http_request(
            'faraday',
            full_url.to_s,
            method.to_s.upcase,
            -> { { headers: headers || {}, body: body } },
            lambda { |response|
              {
                status_code: response.status,
                headers: response.headers.to_h,
                body: response.body
              }
            },
            -> { super(method, url, body, headers, &) }
          )
        end

        private

          def build_url(url)
            # If url is already absolute, return it as-is
            return url if url.to_s.start_with?('http://', 'https://')

            # Build URL from connection's base URL and the relative path
            base_url = url_prefix.to_s.chomp('/')
            relative_url = url.to_s.start_with?('/') ? url.to_s : "/#{url}"
            "#{base_url}#{relative_url}"
          end
      end
    end
  end
end

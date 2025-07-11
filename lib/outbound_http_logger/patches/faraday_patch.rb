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
          # Let Faraday handle URL building and capture the final URL from the response
          # This avoids method name collision with Faraday's private build_url method

          # Use common logging behavior - we'll get the final URL after the request
          log_http_request(
            'faraday',
            url.to_s, # Use the URL as-is initially, will be corrected in logging
            method.to_s.upcase,
            -> { { headers: headers || {}, body: body } },
            lambda { |response|
              {
                status_code: response.status,
                headers: response.headers.to_h,
                body: response.body,
                final_url: response.env.url.to_s # Capture the final resolved URL
              }
            },
            -> { super(method, url, body, headers, &) }
          )
        end
      end
    end
  end
end

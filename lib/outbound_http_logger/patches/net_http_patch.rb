# frozen_string_literal: true

require_relative 'common_patch_behavior'

module OutboundHTTPLogger
  module Patches
    module NetHTTPPatch
      extend CommonPatchBehavior::ClassMethods

      def self.apply!
        apply_patch_safely!(Net::HTTP, Net::HTTP, InstanceMethods, 'Net::HTTP')
      end

      module InstanceMethods
        include CommonPatchBehavior

        def request(req, body = nil, &)
          # Build the full URL (omit default ports)
          scheme = use_ssl? ? 'https' : 'http'
          default_port = use_ssl? ? 443 : 80
          port_part = port == default_port ? '' : ":#{port}"
          url = "#{scheme}://#{address}#{port_part}#{req.path}"

          # Use common logging behavior
          log_http_request(
            'net_http',
            url,
            req.method,
            -> { { headers: extract_request_headers(req), body: body || req.body } },
            lambda { |response|
              {
                status_code: response.code.to_i,
                headers: extract_response_headers(response),
                body: response.body
              }
            },
            -> { super(req, body, &) }
          )
        end

        private

          def extract_request_headers(request)
            headers = {}
            request.each_header do |name, value|
              headers[name] = value
            end
            headers
          end

          def extract_response_headers(response)
            headers = {}
            response.each_header do |name, value|
              headers[name] = value
            end
            headers
          end
      end
    end
  end
end

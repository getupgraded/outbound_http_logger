# frozen_string_literal: true

require_relative 'common_patch_behavior'

module OutboundHTTPLogger
  module Patches
    module HTTPartyPatch
      extend CommonPatchBehavior::ClassMethods

      def self.apply!
        apply_patch_safely!(HTTParty, HTTParty::Request, RequestMethods, 'HTTParty')
      end

      module RequestMethods
        include CommonPatchBehavior

        def perform(&)
          # Get the URL
          url = uri.to_s

          # Use common logging behavior
          log_http_request(
            'httparty',
            url,
            http_method.name.split('::').last.upcase,
            -> { { headers: options[:headers] || {}, body: options[:body] } },
            lambda { |response|
              {
                status_code: response.code,
                headers: response.headers.to_h,
                body: response.body
              }
            },
            -> { super(&) }
          )
        end
      end
    end
  end
end

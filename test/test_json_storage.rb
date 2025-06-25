# frozen_string_literal: true

require "test_helper"

describe "JSON Storage Behavior" do
  let(:model) { OutboundHttpLogger::Models::OutboundRequestLog }

  before do
    OutboundHttpLogger.enable!
  end

  describe "SQLite adapter" do
    # Current test environment uses SQLite

    it "stores JSON fields as strings in SQLite" do
      request_data = {
        headers: { "Content-Type" => "application/json", "Authorization" => "Bearer token" },
        body: '{"name": "John"}'
      }
      response_data = {
        status_code: 200,
        headers: { "Content-Type" => "application/json" },
        body: '{"id": 1, "name": "John"}'
      }

      log = model.log_request("POST", "https://api.example.com/users", request_data, response_data, 0.1)

      _(log).wont_be_nil

      # In SQLite, JSON fields should be stored as strings
      _(log.read_attribute(:request_headers)).must_be_kind_of String
      _(log.read_attribute(:response_headers)).must_be_kind_of String
      _(log.read_attribute(:request_body)).must_be_kind_of String
      _(log.read_attribute(:response_body)).must_be_kind_of String
      _(log.read_attribute(:metadata)).must_be_kind_of String

      # But the accessor methods should return parsed objects
      _(log.request_headers).must_be_kind_of Hash
      _(log.response_headers).must_be_kind_of Hash
      _(log.metadata).must_be_kind_of Hash

      # Verify the content is correct
      _(log.request_headers["Content-Type"]).must_equal "application/json"
      _(log.request_headers["Authorization"]).must_equal "[FILTERED]"
      _(log.response_headers["Content-Type"]).must_equal "application/json"
    end

    it "handles non-JSON string bodies correctly in SQLite" do
      request_data = { body: "plain text body" }
      response_data = { status_code: 200, body: "plain response" }

      log = model.log_request("GET", "https://example.com", request_data, response_data, 0.1)

      # Non-JSON strings should remain as strings
      _(log.read_attribute(:request_body)).must_equal "plain text body"
      _(log.read_attribute(:response_body)).must_equal "plain response"
      _(log.request_body).must_equal "plain text body"
      _(log.response_body).must_equal "plain response"
    end

    it "handles JSON object bodies correctly in SQLite" do
      request_data = { body: { "name" => "John", "age" => 30 } }
      response_data = { status_code: 200, body: { "id" => 1, "created" => true } }

      log = model.log_request("POST", "https://example.com", request_data, response_data, 0.1)

      # Objects should be serialized to JSON strings in SQLite
      _(log.read_attribute(:request_body)).must_be_kind_of String
      _(log.read_attribute(:response_body)).must_be_kind_of String

      # Should be valid JSON
      parsed_request = JSON.parse(log.read_attribute(:request_body))
      _(parsed_request["name"]).must_equal "John"
      _(parsed_request["age"]).must_equal 30

      parsed_response = JSON.parse(log.read_attribute(:response_body))
      _(parsed_response["id"]).must_equal 1
      _(parsed_response["created"]).must_equal true
    end
  end

  describe "JSONB optimization" do
    # Test the JSONB optimization method directly without complex mocking

    it "converts JSON strings to objects for JSONB storage" do
      # Test the JSONB optimization method directly
      test_data = {
        request_headers: { "Content-Type" => "application/json" },
        response_headers: { "Accept" => "application/json" },
        request_body: '{"test": true}',
        response_body: '{"result": "success"}',
        metadata: { "action" => "test" }
      }

      optimized_data = model.send(:optimize_for_jsonb, test_data)

      # Headers and metadata should remain as objects
      _(optimized_data[:request_headers]).must_be_kind_of Hash
      _(optimized_data[:response_headers]).must_be_kind_of Hash
      _(optimized_data[:metadata]).must_be_kind_of Hash

      # JSON string bodies should be converted to objects
      _(optimized_data[:request_body]).must_be_kind_of Hash
      _(optimized_data[:response_body]).must_be_kind_of Hash
      _(optimized_data[:request_body]["test"]).must_equal true
      _(optimized_data[:response_body]["result"]).must_equal "success"
    end

    it "handles non-JSON strings correctly in JSONB optimization" do
      test_data = {
        request_body: "plain text",
        response_body: "not json",
        request_headers: { "Content-Type" => "text/plain" }
      }

      optimized_data = model.send(:optimize_for_jsonb, test_data)

      # Non-JSON strings should remain as strings
      _(optimized_data[:request_body]).must_equal "plain text"
      _(optimized_data[:response_body]).must_equal "not json"
      _(optimized_data[:request_headers]).must_be_kind_of Hash
    end
  end

  describe "consistent interface" do
    it "provides consistent hash interface regardless of storage format" do
      request_data = {
        headers: { "Content-Type" => "application/json", "Authorization" => "Bearer secret" },
        metadata: { "user_id" => 123, "action" => "create" }
      }
      response_data = {
        status_code: 201,
        headers: { "Location" => "/users/123" }
      }

      log = model.log_request("POST", "https://api.example.com/users", request_data, response_data, 0.1)

      # Regardless of how data is stored, the interface should be consistent
      _(log.request_headers).must_be_kind_of Hash
      _(log.response_headers).must_be_kind_of Hash
      _(log.metadata).must_be_kind_of Hash

      # Should be able to access nested data
      _(log.request_headers["Content-Type"]).must_equal "application/json"
      _(log.request_headers["Authorization"]).must_equal "[FILTERED]"
      _(log.response_headers["Location"]).must_equal "/users/123"
      _(log.metadata["user_id"]).must_equal 123
      _(log.metadata["action"]).must_equal "create"
    end
  end
end

# frozen_string_literal: true

class CreateOutboundRequestLogs < ActiveRecord::Migration<%= migration_version %>
  def up
    create_table :outbound_request_logs do |t|
      # Request information
      t.string :http_method, null: false
      t.text :url, null: false
      t.integer :status_code, null: false

      # Request/Response details - Use JSONB for PostgreSQL, JSON for other databases
      if connection.adapter_name == 'PostgreSQL'
        t.jsonb :request_headers, default: {}
        t.jsonb :request_body
        t.jsonb :response_headers, default: {}
        t.jsonb :response_body
        t.jsonb :metadata, default: {}
      else
        t.json :request_headers, default: {}
        t.json :request_body
        t.json :response_headers, default: {}
        t.json :response_body
        t.json :metadata, default: {}
      end

      # Performance metrics
      t.decimal :duration_seconds, precision: 10, scale: 6
      t.decimal :duration_ms, precision: 10, scale: 2

      # Polymorphic association for linking to other models
      t.references :loggable, polymorphic: true, null: true, type: :bigint

      # Timestamp - only created_at needed for append-only logs
      t.datetime :created_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
    end

    # Essential indexes for append-only logging (minimal set)
    add_index :outbound_request_logs, :created_at, name: 'idx_outbound_logs_created_at'
    add_index :outbound_request_logs, [:loggable_type, :loggable_id], name: 'idx_outbound_logs_loggable'

    # Database-specific optimizations
    if connection.adapter_name == 'PostgreSQL'
      # GIN indexes for JSONB columns to enable fast JSON queries
      add_index :outbound_request_logs, :request_headers, using: :gin, name: 'idx_outbound_logs_request_headers_gin'
      add_index :outbound_request_logs, :response_headers, using: :gin, name: 'idx_outbound_logs_response_headers_gin'
      add_index :outbound_request_logs, :metadata, using: :gin, name: 'idx_outbound_logs_metadata_gin'

      # Enable trigram extension for text search if not already enabled
      execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

      # Full text search index on URL using trigrams
      add_index :outbound_request_logs, :url, using: :gin, opclass: :gin_trgm_ops, name: 'idx_outbound_logs_url_gin'
    else
      # For non-PostgreSQL databases, use standard text index with length limit
      add_index :outbound_request_logs, :url, length: 255, name: 'idx_outbound_logs_url'
    end
  end

  def down
    drop_table :outbound_request_logs
  end
end

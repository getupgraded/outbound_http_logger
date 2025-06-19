# frozen_string_literal: true

class CreateOutboundRequestLogs < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :outbound_request_logs do |t|
      t.string :http_method, null: false
      t.text :url, null: false
      t.integer :status_code, null: false
      
      # Use JSONB for PostgreSQL, JSON for other databases
      if connection.adapter_name == 'PostgreSQL'
        t.jsonb :request_headers, default: {}
        t.jsonb :response_headers, default: {}
        t.jsonb :request_body
        t.jsonb :response_body
        t.jsonb :metadata, default: {}
      else
        t.json :request_headers
        t.json :response_headers
        t.json :request_body
        t.json :response_body
        t.json :metadata
      end
      
      t.decimal :duration_seconds, precision: 10, scale: 6
      t.decimal :duration_ms, precision: 10, scale: 2
      
      # Polymorphic association for linking to other models
      t.references :loggable, polymorphic: true, null: true
      
      t.timestamps
    end

    # Add indexes for common queries
    add_index :outbound_request_logs, :http_method
    add_index :outbound_request_logs, :status_code
    add_index :outbound_request_logs, :created_at
    add_index :outbound_request_logs, [:loggable_type, :loggable_id]
    add_index :outbound_request_logs, :duration_ms
    
    # Add index on URL for searching (using prefix for performance)
    add_index :outbound_request_logs, :url, length: 255 if connection.adapter_name != 'PostgreSQL'
    
    # PostgreSQL-specific indexes
    if connection.adapter_name == 'PostgreSQL'
      # GIN indexes for JSONB columns to enable fast JSON queries
      add_index :outbound_request_logs, :request_headers, using: :gin
      add_index :outbound_request_logs, :response_headers, using: :gin
      add_index :outbound_request_logs, :metadata, using: :gin
      
      # Full text search index on URL
      add_index :outbound_request_logs, :url, using: :gin, opclass: :gin_trgm_ops
    end
  end
end

# frozen_string_literal: true

class CreateJetstreamBridgeInboxEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :jetstream_bridge_inbox_events do |t|
      t.string :event_id, null: false, index: { unique: true }
      t.string :resource_type, null: false
      t.string :resource_id, null: false
      t.string :event_type, null: false
      t.string :source_app, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: 'pending'
      t.text :error_message
      t.integer :attempts, default: 0
      t.datetime :processed_at
      t.datetime :failed_at
      t.timestamps

      # Explicit shorter name to stay under PostgreSQL's 63-char index limit
      t.index [:resource_type, :resource_id], name: 'index_inbox_events_on_resource_type_and_resource_id'
      t.index [:status, :created_at]
      t.index :source_app
    end
  end
end

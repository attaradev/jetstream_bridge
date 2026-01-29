# frozen_string_literal: true

class CreateJetstreamBridgeOutboxEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :jetstream_bridge_outbox_events do |t|
      t.string :event_id, null: false, index: { unique: true }
      t.string :resource_type, null: false
      t.string :resource_id, null: false
      t.string :event_type, null: false
      t.string :destination_app, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: 'pending'
      t.text :error_message
      t.integer :attempts, default: 0
      t.datetime :published_at
      t.datetime :failed_at
      t.timestamps

      # Shorter explicit name to avoid exceeding PostgreSQL's 63-character index limit
      t.index [:resource_type, :resource_id], name: 'index_outbox_events_on_resource_type_and_resource_id'
      t.index [:status, :created_at]
      t.index :destination_app
    end
  end
end

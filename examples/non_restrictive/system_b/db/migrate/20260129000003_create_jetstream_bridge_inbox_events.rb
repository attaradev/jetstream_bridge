# frozen_string_literal: true

class CreateJetstreamBridgeInboxEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :jetstream_bridge_inbox_events do |t|
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.string :resource_type
      t.string :resource_id
      t.text :payload, null: false
      t.string :status, default: 'received', null: false
      t.text :error_message
      t.integer :processing_attempts, default: 0, null: false
      t.datetime :processed_at
      t.datetime :failed_at

      t.timestamps
    end

    add_index :jetstream_bridge_inbox_events, :event_id, unique: true
    add_index :jetstream_bridge_inbox_events, :status
    add_index :jetstream_bridge_inbox_events, :created_at
  end
end

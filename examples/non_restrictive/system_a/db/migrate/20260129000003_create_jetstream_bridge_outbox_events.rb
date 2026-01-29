# frozen_string_literal: true

class CreateJetstreamBridgeOutboxEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :jetstream_bridge_outbox_events do |t|
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.string :resource_type
      t.string :resource_id
      t.text :payload, null: false
      t.string :subject
      t.string :status, default: 'pending', null: false
      t.text :error_message
      t.integer :publish_attempts, default: 0, null: false
      t.datetime :published_at
      t.datetime :failed_at

      t.timestamps
    end

    add_index :jetstream_bridge_outbox_events, :event_id, unique: true
    add_index :jetstream_bridge_outbox_events, :status
    add_index :jetstream_bridge_outbox_events, :created_at
  end
end

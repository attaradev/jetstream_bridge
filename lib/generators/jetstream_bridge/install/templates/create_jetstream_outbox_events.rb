# frozen_string_literal: true

# Create the outbox table.
class CreateJetstreamOutboxEvents < ActiveRecord::Migration[6.1]
  def change
    create_table :jetstream_outbox_events do |t|
      t.string   :resource_type, null: false
      t.string   :resource_id,   null: false
      t.string   :event_type,    null: false
      t.jsonb    :payload,       null: false, default: {}
      t.datetime :published_at
      t.integer  :attempts, default: 0
      t.text     :last_error
      t.timestamps
    end

    add_index :jetstream_outbox_events, %i[resource_type resource_id], name: 'idx_js_outbox_resource'
    add_index :jetstream_outbox_events, :published_at
  end
end

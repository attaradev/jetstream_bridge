# frozen_string_literal: true

# Create the inbox events table.
class CreateJetstreamInboxEvents < ActiveRecord::Migration[6.1]
  def change
    create_table :jetstream_inbox_events do |t|
      t.string   :event_id,  null: false
      t.string   :subject,   null: false
      t.datetime :processed_at
      t.text     :error
      t.timestamps
    end

    add_index :jetstream_inbox_events, :event_id, unique: true
  end
end

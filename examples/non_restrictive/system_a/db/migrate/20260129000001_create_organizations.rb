# frozen_string_literal: true

class CreateOrganizations < ActiveRecord::Migration[7.0]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :domain, null: false
      t.boolean :active, default: true, null: false

      t.timestamps
    end

    add_index :organizations, :domain, unique: true
  end
end

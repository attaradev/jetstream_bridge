# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[7.0]
  def change
    create_table :users do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.string :email, null: false
      t.string :role
      t.boolean :active, default: true, null: false

      t.timestamps
    end

    add_index :users, :email, unique: true
  end
end

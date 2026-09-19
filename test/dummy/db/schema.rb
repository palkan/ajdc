# frozen_string_literal: true

# The dummy application's own tables; the gem's tables come from db/durable_schema.rb.
ActiveRecord::Schema[8.1].define(version: 1) do
  create_table "cards", force: :cascade do |t|
    t.string "title"
    t.string "state"
    t.string "verdict"
    t.timestamps
  end

  create_table "licenses", force: :cascade do |t|
    t.string "state", default: "active", null: false
    t.datetime "expires_at", null: false
    t.timestamps
  end

  create_table "chats", force: :cascade do |t|
    t.integer "turns", default: 0, null: false
    t.integer "turn_limit", null: false
    t.integer "approval_turn"
    t.boolean "approved", default: false, null: false
    t.timestamps
  end
end

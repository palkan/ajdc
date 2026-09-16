# frozen_string_literal: true

# The dummy application's own tables; the gem's tables come from db/durable_schema.rb.
ActiveRecord::Schema[8.1].define(version: 1) do
  create_table "cards", force: :cascade do |t|
    t.string "title"
    t.string "state"
    t.string "verdict"
    t.timestamps
  end
end

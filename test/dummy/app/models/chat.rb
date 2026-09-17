# frozen_string_literal: true

# Stands in for a RubyLLM chat: `tick!` is one agent turn, `needs_approval?`
# is true at one turn until a person approves.
class Chat < ApplicationRecord
  def tick! = increment!(:turns)

  def done? = turns >= turn_limit

  def needs_approval? = turns == approval_turn && !approved?

  def approve! = update!(approved: true)
end

# frozen_string_literal: true

class License < ApplicationRecord
  def expired! = update!(state: "expired")

  def revoke! = update!(state: "revoked")
end

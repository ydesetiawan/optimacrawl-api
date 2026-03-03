# frozen_string_literal: true

class ReplaceLicenseStatusWithHasLicenseAndLicenseNumbers < ActiveRecord::Migration[8.1]
  def change
    remove_column :website_data, :license_status, :string
    add_column :website_data, :has_license, :boolean, default: false
    add_column :website_data, :license_numbers, :jsonb
  end
end

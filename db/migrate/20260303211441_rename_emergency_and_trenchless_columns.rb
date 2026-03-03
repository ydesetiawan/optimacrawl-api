class RenameEmergencyAndTrenchlessColumns < ActiveRecord::Migration[8.1]
  def change
    rename_column :website_data, :emergency_service, :has_emergency_service
    rename_column :website_data, :trenchless_technologies, :trenchless_technologies_list
  end
end

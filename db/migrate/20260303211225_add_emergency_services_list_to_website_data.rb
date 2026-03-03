class AddEmergencyServicesListToWebsiteData < ActiveRecord::Migration[8.1]
  def change
    add_column :website_data, :emergency_services_list, :jsonb
  end
end

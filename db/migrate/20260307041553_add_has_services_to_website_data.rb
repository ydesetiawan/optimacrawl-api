class AddHasServicesToWebsiteData < ActiveRecord::Migration[8.1]
  def change
    add_column :website_data, :has_services, :boolean
  end
end

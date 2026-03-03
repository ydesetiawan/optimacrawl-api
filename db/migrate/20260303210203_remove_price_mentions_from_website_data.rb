class RemovePriceMentionsFromWebsiteData < ActiveRecord::Migration[8.1]
  def change
    remove_column :website_data, :price_mentions, :jsonb
  end
end

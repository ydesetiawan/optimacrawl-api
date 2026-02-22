# frozen_string_literal: true

module Api
  module V1
    class WebsiteDataController < ApplicationController
      # Since we don't have the BaseController or JsonRendering concern fully mocked in this new app yet,
      # we'll implement a clean JSON response directly conforming to standard patterns.

      def create
        url = website_data_params[:url]

        if url.blank?
          render json: { error: "URL parameter is required" }, status: :unprocessable_entity
          return
        end

        # Run the crawler service
        service = WebsiteCrawlerService.new(url)
        record = service.perform

        if record.persisted?
          render json: WebsiteDataSerializer.new(record).serializable_hash, status: :created
        else
          render json: { errors: record.errors.full_messages }, status: :unprocessable_entity
        end
      rescue StandardError => e
        render json: { error: "Crawling failed: #{e.message}" }, status: :internal_server_error
      end

      private

      def website_data_params
        params.permit(:url)
      end
    end
  end
end

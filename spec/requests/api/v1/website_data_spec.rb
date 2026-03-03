# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'api/v1/website_data', type: :request do
  path '/api/v1/website_data' do
    post('Crawl Website Data') do
      tags 'Website Data Crawler'
      consumes 'application/json'
      produces 'application/json'

      parameter name: :website_data, in: :body, schema: {
        type: :object,
        properties: {
          url: { type: :string, example: 'https://brooklynsewersolutions.com' }
        },
        required: %w[url]
      }

      response(201, 'created') do
        let(:website_data) { { url: 'https://brooklynsewersolutions.com' } }

        # Note: We are mocking the service here so we don't actually hit the live internet during test suites
        before do
          mock_service = instance_double(WebsiteCrawlerService)
          mock_record = WebsiteData.new(
            url: 'https://brooklynsewersolutions.com',
            business_name: 'Brooklyn Sewer Solutions',
            license_status: '12345',
            has_trenchless: true,
            emergency_service: true,
            specific_equipment: [ 'Ridgid', 'Picote' ],
            services_list: [ 'Drain Cleaning', 'Camera Inspection' ],
            trenchless_technologies: [ 'CIPP (Cured-In-Place Pipe)', 'Pipe Bursting' ],
            price_mentions: [ '$99 Drain Cleaning' ]
          )

          # Allow the record to appear persisted for the controller
          allow(mock_record).to receive(:persisted?).and_return(true)

          allow(WebsiteCrawlerService).to receive(:new).with('https://brooklynsewersolutions.com').and_return(mock_service)
          allow(mock_service).to receive(:perform).and_return(mock_record)
        end

        run_test! do |response|
          data = JSON.parse(response.body)
          expect(data['data']).to be_present
          expect(data['data']['attributes']['url']).to eq('https://brooklynsewersolutions.com')
          expect(data['data']['attributes']['business_name']).to eq('Brooklyn Sewer Solutions')
          expect(data['data']['attributes']['has_trenchless']).to be true
          expect(data['data']['attributes']['trenchless_technologies']).to include('CIPP (Cured-In-Place Pipe)')
        end
      end

      response(422, 'unprocessable entity (missing url)') do
        let(:website_data) { { url: '' } }
        run_test!
      end
    end
  end
end

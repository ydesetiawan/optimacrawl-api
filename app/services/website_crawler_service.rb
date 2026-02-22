# frozen_string_literal: true

require "nokogiri"
require "open-uri"

class WebsiteCrawlerService
  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

  def initialize(url)
    @base_url = clean_url(url)
    @extracted_data = {
      url: @base_url,
      business_name: nil,
      license_status: "Not found",
      trenchless_technology: false,
      emergency_service: false,
      specific_equipment: [],
      services_list: [],
      price_mentions: []
    }
  end

  def perform
    return WebsiteData.new(url: @base_url) unless valid_url?

    urls_to_crawl = fetch_target_urls

    # Fallback to base url if no sitemap or specific plumbing pages found
    urls_to_crawl = [ @base_url ] if urls_to_crawl.empty?

    Rails.logger.info("Crawling urls: #{urls_to_crawl}")
    crawl_pages(urls_to_crawl.take(10)) # Limit to 10 pages for performance

    save_website_data
  end

  private

  def clean_url(url)
    return nil if url.blank?

    url = "https://#{url}" unless url.start_with?("http")
    url.chomp("/")
  end

  def valid_url?
    @base_url.present? && URI.parse(@base_url).is_a?(URI::HTTP)
  rescue URI::InvalidURIError
    false
  end

  def can_crawl_path?(path)
    # Basic robots.txt compliance
    begin
      robots_url = "#{@base_url}/robots.txt"
      robots_content = URI.open(robots_url, "User-Agent" => USER_AGENT, read_timeout: 5).read

      # Simple check: if Disallow: / is present for all agents or our agent
      return false if robots_content.match?(/User-agent:\s*\*\s*Disallow:\s*\//i)
      true
    rescue StandardError
      # If robots.txt is missing or errors out, assume we can crawl
      true
    end
  end

  def fetch_target_urls
    return [] unless can_crawl_path?("/")

    begin
      sitemap_url = "#{@base_url}/sitemap.xml"
      xml = URI.open(sitemap_url, "User-Agent" => USER_AGENT, read_timeout: 10).read
      doc = Nokogiri::XML(xml)

      # Extract all loc (URL) tags
      all_urls = doc.xpath("//xmlns:loc").map(&:text)

      # If it is a sitemap index (common in WordPress/Yoast), try to fetch the page or post sitemaps instead
      if all_urls.any? { |url| url.include?("page-sitemap") || url.include?("post-sitemap") }
        nested_urls = []
        all_urls.select { |u| u.include?("sitemap") }.each do |index_url|
          begin
            nested_xml = URI.open(index_url, "User-Agent" => USER_AGENT, read_timeout: 10).read
            nested_doc = Nokogiri::XML(nested_xml)
            nested_urls.concat(nested_doc.xpath("//xmlns:loc").map(&:text))
          rescue StandardError
            next
          end
        end
        all_urls = nested_urls
      end

      # Filter for plumbing/sewer keywords, or return home/about/services pages
      target_keywords = %w[plumbing sewer drain pipe trenchless services about contact]

      filtered = all_urls.select do |url|
        !url.match?(/\.(jpg|jpeg|png|gif|pdf)$/i) && target_keywords.any? { |kw| url.downcase.include?(kw) }
      end

      # Always ensure the homepage is included as it often contains the main business name / license info
      filtered.unshift(@base_url)
      filtered.uniq
    rescue StandardError
      []
    end
  end

  def crawl_pages(urls)
    combined_text = ""

    urls.each do |url|
      begin
        html = URI.open(url, "User-Agent" => USER_AGENT, read_timeout: 10).read
        doc = Nokogiri::HTML(html)

        # Remove script and style tags to just get visible text
        doc.search("script, style").remove

        page_text = doc.text.gsub(/\s+/, " ").strip
        combined_text += " #{page_text}"
      rescue StandardError => e
        Rails.logger.error("Crawler failed on #{url}: #{e.message}")
        next
      end
    end

    extract_data_from_text(combined_text)
  end

  def extract_data_from_text(text)
    lower_text = text.downcase

    # 1. Business Name (Look for common copyright or broader patterns)
    if @extracted_data[:business_name].nil?
      match = text.match(/©\s*(?:20\d{2})?\s*([a-zA-Z\s]+?)(?:\.|\||All|LLC|Inc|Company|Services)/i) ||
              text.match(/(?:Welcome to|Call)\s+([A-Z][a-zA-Z\s]+?)(?:LLC|Inc|Company)/)

      @extracted_data[:business_name] = match[1].strip if match

      # Fallback to domain name if regex misses
      if @extracted_data[:business_name].nil? || @extracted_data[:business_name].length < 3
        domain_match = @base_url.match(/https?:\/\/(?:www\.)?([^\.]+)\./)
        @extracted_data[:business_name] = domain_match[1].capitalize if domain_match
      end
    end

    # 2. License Status
    license_match = text.match(/(?:license|lic|master plumber)\s*(?:#|no\.?|number)?\s*(:|-)?\s*([A-Z0-9-]+)/i)
    @extracted_data[:license_status] = license_match[2].strip if license_match

    # 3. Trenchless Technology
    @extracted_data[:trenchless_technology] = lower_text.match?(/trenchless|cipp|lining|pipe bursting/)

    # 4. Emergency Service
    @extracted_data[:emergency_service] = lower_text.match?(/24\/7|emergency|24 hours|around the clock/)

    # 5. Specific Equipment
    brands = %w[ridgid picote nuflow spartan hammerhead perma-liner]
    brands.each do |brand|
      @extracted_data[:specific_equipment] << brand.capitalize if lower_text.include?(brand)
    end
    @extracted_data[:specific_equipment].uniq!

    # 6. Services List
    common_services = [
      "hydro-jetting", "camera inspection", "excavation",
      "drain cleaning", "pipe relining", "sewer repair",
      "water heater repair", "leak detection", "hydro jetting", "video inspection"
    ]

    common_services.each do |service|
      @extracted_data[:services_list] << service.split.map(&:capitalize).join(" ") if lower_text.include?(service)
    end
    @extracted_data[:services_list].uniq!

    # 7. Price Mentions
    prices = text.scan(/\$[\d,]+(?:\.\d{2})?\s+(?:for|off|drain|cleaning|service|coupon|discount)?/i).map(&:strip)
    @extracted_data[:price_mentions] = prices.uniq
  end

  def save_website_data
    WebsiteData.create(@extracted_data)
  end
end

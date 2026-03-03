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
      has_trenchless: false,
      emergency_service: false,
      specific_equipment: [],
      services_list: [],
      trenchless_technologies: [],
      price_mentions: []
    }
  end

  def perform
    return WebsiteData.new(url: @base_url) unless valid_url?

    urls_to_crawl = fetch_target_urls

    # Fallback: discover internal links from homepage if sitemap yielded nothing useful
    if urls_to_crawl.empty? || urls_to_crawl == [ @base_url ]
      urls_to_crawl = discover_links_from_homepage
      urls_to_crawl.unshift(@base_url)
      urls_to_crawl.uniq!
    end

    # Final fallback to base url only
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
      target_keywords = %w[plumbing sewer drain pipe trenchless lining services about contact]

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

  def discover_links_from_homepage
    html = URI.open(@base_url, "User-Agent" => USER_AGENT, read_timeout: 10).read
    doc = Nokogiri::HTML(html)

    base_host = URI.parse(@base_url).host
    target_keywords = %w[plumbing sewer drain pipe trenchless lining services about contact]

    links = doc.css("a[href]").filter_map do |a|
      href = a["href"].to_s.strip
      next if href.empty? || href.start_with?("#", "mailto:", "tel:", "javascript:")

      # Build absolute URL from relative paths
      absolute = if href.start_with?("http")
                   href
      else
                   URI.join(@base_url + "/", href).to_s
      end

      # Only keep same-domain links
      next unless URI.parse(absolute).host == base_host
      # Skip binary/media files
      next if absolute.match?(/\.(jpg|jpeg|png|gif|pdf|css|js|ico|svg|woff|mp4)$/i)
      # Filter for relevant keywords in the URL path
      next unless target_keywords.any? { |kw| absolute.downcase.include?(kw) }

      absolute.chomp("/")
    end

    links.uniq
  rescue StandardError => e
    Rails.logger.error("Link discovery failed for #{@base_url}: #{e.message}")
    []
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

    # 3. Has Trenchless (boolean)
    @extracted_data[:has_trenchless] = lower_text.match?(/trenchless|cipp|lining|pipe bursting/)

    # 4. Emergency Service
    @extracted_data[:emergency_service] = lower_text.match?(/24\/7|emergency|24 hours|around the clock/)

    # 5. Specific Equipment
    brands = %w[ridgid picote nuflow spartan hammerhead perma-liner]
    brands.each do |brand|
      @extracted_data[:specific_equipment] << brand.capitalize if lower_text.include?(brand)
    end
    @extracted_data[:specific_equipment].uniq!

    # 6. Services List
    # Each entry: [search_term, label] — multiple search terms can map to the same label
    service_mappings = [
      [ "hydro-jetting", "Hydro-Jetting" ],
      [ "hydro jetting", "Hydro-Jetting" ],
      [ "hydrojetting", "Hydro-Jetting" ],
      [ "water jetting", "Hydro-Jetting" ],
      [ "high pressure jetting", "Hydro-Jetting" ],
      [ "camera inspection", "Camera Inspection" ],
      [ "video inspection", "Camera Inspection" ],
      [ "sewer camera", "Camera Inspection" ],
      [ "pipe inspection", "Camera Inspection" ],
      [ "cctv inspection", "Camera Inspection" ],
      [ "excavation", "Excavation" ],
      [ "dig up", "Excavation" ],
      [ "drain cleaning", "Drain Cleaning" ],
      [ "drain clearing", "Drain Cleaning" ],
      [ "clogged drain", "Drain Cleaning" ],
      [ "drain clog", "Drain Cleaning" ],
      [ "sewer line cleaning", "Sewer Line Cleaning" ],
      [ "sewer cleaning", "Sewer Line Cleaning" ],
      [ "sewer rodding", "Sewer Line Cleaning" ],
      [ "sewer maintenance", "Sewer Line Cleaning" ],
      [ "root removal", "Root Removal" ],
      [ "root intrusion", "Root Removal" ],
      [ "tree root", "Root Removal" ],
      [ "root cutting", "Root Removal" ],
      [ "pipe repair", "Pipe Repair" ],
      [ "sewer repair", "Pipe Repair" ],
      [ "drain repair", "Pipe Repair" ],
      [ "pipe fix", "Pipe Repair" ],
      [ "pipe replacement", "Pipe Replacement" ],
      [ "sewer replacement", "Pipe Replacement" ],
      [ "repipe", "Pipe Replacement" ],
      [ "re-pipe", "Pipe Replacement" ],
      [ "backflow testing", "Backflow Testing" ],
      [ "backflow prevention", "Backflow Testing" ],
      [ "backflow certification", "Backflow Testing" ],
      [ "backflow inspection", "Backflow Testing" ],
      [ "grease trap cleaning", "Grease Trap Cleaning" ],
      [ "grease trap", "Grease Trap Cleaning" ],
      [ "grease interceptor", "Grease Trap Cleaning" ],
      [ "smoke testing", "Smoke Testing" ],
      [ "smoke test", "Smoke Testing" ]
    ]

    service_mappings.each do |term, label|
      if lower_text.include?(term)
        @extracted_data[:services_list] << label
      end
    end
    @extracted_data[:services_list].uniq!

    # 7. Trenchless Technologies List
    # Each entry: [search_term, label] — multiple search terms can map to the same label
    trenchless_mappings = [
      [ "trenchless", "Trenchless" ],
      [ "cipp", "CIPP (Cured-In-Place Pipe)" ],
      [ "cured-in-place pipe", "CIPP (Cured-In-Place Pipe)" ],
      [ "cured in place", "CIPP (Cured-In-Place Pipe)" ],
      [ "cured in place pipe", "CIPP (Cured-In-Place Pipe)" ],
      [ "pipe lining", "Pipe Lining" ],
      [ "sewer lining", "Pipe Lining" ],
      [ "pipe relining", "Pipe Lining" ],
      [ "sewer relining", "Pipe Lining" ],
      [ "drain lining", "Pipe Lining" ],
      [ "pipe bursting", "Pipe Bursting" ],
      [ "pipe burst", "Pipe Bursting" ],
      [ "slip lining", "Slip Lining" ],
      [ "sliplining", "Slip Lining" ],
      [ "spray lining", "Spray Lining / Epoxy Coating" ],
      [ "epoxy coating", "Spray Lining / Epoxy Coating" ],
      [ "epoxy lining", "Spray Lining / Epoxy Coating" ],
      [ "horizontal directional drilling", "Horizontal Directional Drilling (HDD)" ],
      [ "directional drilling", "Horizontal Directional Drilling (HDD)" ],
      [ "hdd drilling", "Horizontal Directional Drilling (HDD)" ],
      [ "microtunneling", "Microtunneling" ],
      [ "micro tunneling", "Microtunneling" ],
      [ "auger boring", "Auger Boring" ],
      [ "pipe reaming", "Pipe Reaming" ],
      [ "grouting", "Grouting" ]
    ]

    trenchless_mappings.each do |term, label|
      if lower_text.include?(term)
        @extracted_data[:trenchless_technologies] << label
      end
    end
    @extracted_data[:trenchless_technologies].uniq!

    # 8. Price Mentions
    prices = text.scan(/\$[\d,]+(?:\.\d{2})?\s+(?:for|off|drain|cleaning|service|coupon|discount)?/i).map(&:strip)
    @extracted_data[:price_mentions] = prices.uniq
  end

  def save_website_data
    WebsiteData.create(@extracted_data)
  end
end

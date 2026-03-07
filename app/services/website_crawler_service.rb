# frozen_string_literal: true

require "nokogiri"
require "open-uri"

class WebsiteCrawlerService # rubocop:disable Metrics/ClassLength
  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

  def initialize(url)
    @base_url = clean_url(url)
    @extracted_data = {
      url: @base_url,
      business_name: nil,
      has_license: false,
      license_numbers: [],
      has_trenchless: false,
      has_emergency_service: false,
      has_services: false,
      about_us: nil,
      equipment_brands_list: nil,
      services_list: nil,
      trenchless_technologies_list: [],
      emergency_services_list: []
    }
  end

  def perform
    return WebsiteData.new(url: @base_url) unless valid_url?

    begin
      urls_to_crawl = fetch_target_urls

      if urls_to_crawl.empty? || urls_to_crawl == [ @base_url ]
        urls_to_crawl = discover_links_from_homepage
        urls_to_crawl.unshift(@base_url)
        urls_to_crawl.uniq!
      end

      urls_to_crawl = [ @base_url ] if urls_to_crawl.empty?

      Rails.logger.info("Crawling urls: #{urls_to_crawl.size} URLs")
      crawl_pages(urls_to_crawl.take(10)) # Limit to 10 pages for performance

      save_website_data
    rescue StandardError => e
      Rails.logger.error("Crawler failed to save for #{@base_url}: #{e.message}")
      save_website_data # Save whatever we got
    end
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

  def can_crawl_path?(_path)
    robots_url = "#{@base_url}/robots.txt"
    robots_content = URI.open(robots_url, "User-Agent" => USER_AGENT, :read_timeout => 5).read

    # Simple check: if Disallow: / is present for all agents
    return false if robots_content.match?(%r{User-agent:\s*\*\s*Disallow:\s*/}i)

    true
  rescue StandardError
    # If robots.txt is missing or errors out, assume we can crawl
    true
  end

  def fetch_target_urls
    return [] unless can_crawl_path?("/")

    sitemap_url = "#{@base_url}/sitemap.xml"
    xml = URI.open(sitemap_url, "User-Agent" => USER_AGENT, :read_timeout => 10).read
    doc = Nokogiri::XML(xml)

    # Extract all loc (URL) tags
    all_urls = doc.xpath("//xmlns:loc").map(&:text)

    # If it is a sitemap index, try to fetch nested sitemaps
    if all_urls.any? { |url| url.include?("page-sitemap") || url.include?("post-sitemap") }
      nested_urls = []
      all_urls.select { |u| u.include?("sitemap") }.each do |index_url|
        nested_xml = URI.open(index_url, "User-Agent" => USER_AGENT, :read_timeout => 10).read
        nested_doc = Nokogiri::XML(nested_xml)
        nested_urls.concat(nested_doc.xpath("//xmlns:loc").map(&:text))
      rescue StandardError
        next
      end
      all_urls = nested_urls
    end

    # Filter for plumbing/sewer keywords
    target_keywords = %w[plumbing sewer drain pipe trenchless lining services about contact]

    filtered = all_urls.select do |url|
      !url.match?(/\.(jpg|jpeg|png|gif|pdf)$/i) && target_keywords.any? { |kw| url.downcase.include?(kw) }
    end

    filtered.unshift(@base_url)
    filtered.uniq
  rescue StandardError
    []
  end

  def discover_links_from_homepage
    html = URI.open(@base_url, "User-Agent" => USER_AGENT, :read_timeout => 10).read
    doc = Nokogiri::HTML(html)

    base_host = URI.parse(@base_url).host
    target_keywords = %w[plumbing sewer drain pipe trenchless lining services about contact]

    links = doc.css("a[href]").filter_map do |a|
      href = a["href"].to_s.strip
      next if href.empty? || href.start_with?("#", "mailto:", "tel:", "javascript:")

      absolute = if href.start_with?("http")
                   href
      else
                   URI.join("#{@base_url}/", href).to_s
      end

      next unless URI.parse(absolute).host == base_host
      next if absolute.match?(/\.(jpg|jpeg|png|gif|pdf|css|js|ico|svg|woff|mp4)$/i)
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
      html = URI.open(url, "User-Agent" => USER_AGENT, :read_timeout => 10).read
      doc = Nokogiri::HTML(html)

      # Remove script and style tags to just get visible text
      doc.search("script, style").remove

      # Extract "About Us" content if not yet found
      extract_about_us(doc, url) if @extracted_data[:about_us].nil?

      page_text = doc.text.gsub(/\s+/, " ").strip
      combined_text += " #{page_text}"
    rescue StandardError => e
      Rails.logger.error("Crawler failed on #{url}: #{e.message}")
      next
    end

    extract_data_from_text(combined_text)
  end

  def extract_data_from_text(text)
    lower_text = text.downcase

    extract_business_name(text)
    extract_license_info(text)
    extract_trenchless_flag(lower_text)
    extract_emergency_flag(lower_text)
    extract_emergency_services_list(lower_text)
    extract_equipment_brands(lower_text)
    extract_services_list(lower_text)
    extract_trenchless_technologies(lower_text)
  end

  def extract_about_us(doc, url)
    return unless @extracted_data[:about_us].nil?

    about_paragraphs = []

    # Strategy 1: If the URL itself is an "about" page, grab all meaningful <p> tags
    if url.downcase.match?(/about|who-we-are|our-story|our-company/)
      about_paragraphs = doc.css("main p, article p, .content p, .entry-content p, section p, div p")
                            .map { |p| p.text.gsub(/\s+/, " ").strip }
                            .select { |t| t.length >= 40 }
    end

    # Strategy 2: Look for headings that contain "about" keywords and gather sibling paragraphs
    if about_paragraphs.empty?
      about_headings = doc.css("h1, h2, h3, h4").select do |h|
        h.text.downcase.match?(/about\s*(us)?|who\s*we\s*are|our\s*story|our\s*company/)
      end

      about_headings.each do |heading|
        # Walk through next siblings collecting paragraphs until another heading or section break
        sibling = heading.next_element
        while sibling
          break if sibling.name.match?(/^h[1-4]$/)

          if sibling.name == "p"
            text = sibling.text.gsub(/\s+/, " ").strip
            about_paragraphs << text if text.length >= 40
          end

          # Also look for paragraphs nested inside the sibling (e.g., inside a <div>)
          if sibling.name != "p"
            sibling.css("p").each do |p|
              text = p.text.gsub(/\s+/, " ").strip
              about_paragraphs << text if text.length >= 40
            end
          end

          sibling = sibling.next_element
        end

        break if about_paragraphs.any?
      end
    end

    return if about_paragraphs.empty?

    @extracted_data[:about_us] = about_paragraphs.uniq.join("\n\n")
  end

  def extract_business_name(text)
    return unless @extracted_data[:business_name].nil?

    match = text.match(/©\s*(?:20\d{2})?\s*([a-zA-Z\s]+?)(?:\.|\||All|LLC|Inc|Company|Services)/i) ||
            text.match(/(?:Welcome to|Call)\s+([A-Z][a-zA-Z\s]+?)(?:LLC|Inc|Company)/)

    @extracted_data[:business_name] = match[1].strip if match

    # Fallback to domain name
    return unless @extracted_data[:business_name].nil? || @extracted_data[:business_name].length < 3

    domain_match = @base_url.match(%r{https?://(?:www\.)?([^.]+)\.})
    @extracted_data[:business_name] = domain_match[1].capitalize if domain_match
  end

  def extract_license_info(text)
    license_numbers = text.scan(/(?:license|lic|master plumber)\s*(?:no\.?|number)?\s*[:|-]?\s*#?\s*(\d{2,4}-\d{4,10})/i)
                          .flatten
                          .map(&:strip)
                          .uniq

    return unless license_numbers.any?

    @extracted_data[:has_license] = true
    @extracted_data[:license_numbers] = license_numbers
  end

  def extract_trenchless_flag(lower_text)
    @extracted_data[:has_trenchless] = lower_text.match?(/trenchless|cipp|lining|pipe bursting/)
  end

  def extract_emergency_flag(lower_text)
    @extracted_data[:has_emergency_service] = lower_text.match?(%r{24/7|emergency|24 hours|around the clock})
  end

  def extract_emergency_services_list(lower_text)
    emergency_mappings = [
      [ "24/7", "24/7 Available" ],
      [ "24 hours", "24/7 Available" ],
      [ "24-hour", "24/7 Available" ],
      [ "around the clock", "24/7 Available" ],
      [ "24 hour service", "24/7 Available" ],
      [ "emergency service", "Emergency Available" ],
      [ "emergency plumb", "Emergency Available" ],
      [ "emergency repair", "Emergency Available" ],
      [ "emergency call", "Emergency Available" ],
      [ "emergency response", "Emergency Available" ],
      [ "same-day", "Rapid/Same-Day Response" ],
      [ "same day", "Rapid/Same-Day Response" ],
      [ "rapid response", "Rapid/Same-Day Response" ],
      [ "fast response", "Rapid/Same-Day Response" ],
      [ "quick response", "Rapid/Same-Day Response" ],
      [ "after-hours", "After-Hours Available" ],
      [ "after hours", "After-Hours Available" ],
      [ "nights and weekends", "After-Hours Available" ],
      [ "weekend service", "After-Hours Available" ],
      [ "evening service", "After-Hours Available" ]
    ]

    emergency_mappings.each do |term, label|
      @extracted_data[:emergency_services_list] << label if lower_text.include?(term)
    end
    @extracted_data[:emergency_services_list].uniq!

    return unless @extracted_data[:emergency_services_list].empty?

    @extracted_data[:emergency_services_list] << "No Emergency Service"
  end

  def extract_equipment_brands(lower_text)
    equipment_mappings = [
      [ "caterpillar", "Caterpillar (CAT)", "Excavation Equipment" ],
      [ "cat excavat", "Caterpillar (CAT)", "Excavation Equipment" ],
      [ "case construct", "Case", "Excavation Equipment" ],
      [ "case excavat", "Case", "Excavation Equipment" ],
      [ "komatsu", "Komatsu", "Excavation Equipment" ],
      [ "john deere", "John Deere", "Excavation Equipment" ],
      [ "volvo construct", "Volvo", "Excavation Equipment" ],
      [ "volvo excavat", "Volvo", "Excavation Equipment" ],
      [ "kubota", "Kubota", "Excavation Equipment" ],
      [ "vactor", "Vactor", "Vacuum / Hydro-Jetting Trucks" ],
      [ "aquatech", "Aqua", "Vacuum / Hydro-Jetting Trucks" ],
      [ "aqua jet", "Aqua", "Vacuum / Hydro-Jetting Trucks" ],
      [ "aqua pro", "Aqua", "Vacuum / Hydro-Jetting Trucks" ],
      [ "vortex", "Vortex", "Vacuum / Hydro-Jetting Trucks" ],
      [ "super products", "Super Products", "Vacuum / Hydro-Jetting Trucks" ],
      [ "freightliner", "Freightliner", "Vacuum / Hydro-Jetting Trucks" ],
      [ "spartan tool", "Spartan Tool", "Vacuum / Hydro-Jetting Trucks" ],
      [ "spartan jet", "Spartan Tool", "Vacuum / Hydro-Jetting Trucks" ],
      [ "general wire", "General Wire", "Vacuum / Hydro-Jetting Trucks" ],
      [ "harben", "Harben", "Vacuum / Hydro-Jetting Trucks" ],
      [ "ridgid", "RIDGID", "CCTV / Pipe Inspection" ],
      [ "envirosight", "Envirosight", "CCTV / Pipe Inspection" ],
      [ "aries industries", "Aries Industries", "CCTV / Pipe Inspection" ],
      [ "ipek", "iPEK", "CCTV / Pipe Inspection" ],
      [ "pearpoint", "Pearpoint", "CCTV / Pipe Inspection" ],
      [ "cobra camera", "Cobra", "CCTV / Pipe Inspection" ],
      [ "cobra inspect", "Cobra", "CCTV / Pipe Inspection" ],
      [ "hammerhead", "Hammerhead", "Trenchless / Pipe Lining & Bursting" ],
      [ "tt technologies", "TT Technologies", "Trenchless / Pipe Lining & Bursting" ],
      [ "nuflow", "NuFlow", "Trenchless / Pipe Lining & Bursting" ],
      [ "nu flow", "NuFlow", "Trenchless / Pipe Lining & Bursting" ],
      [ "perma-pipe", "Perma-Pipe", "Trenchless / Pipe Lining & Bursting" ],
      [ "perma pipe", "Perma-Pipe", "Trenchless / Pipe Lining & Bursting" ],
      [ "perma-liner", "Perma-Liner", "Trenchless / Pipe Lining & Bursting" ],
      [ "perma liner", "Perma-Liner", "Trenchless / Pipe Lining & Bursting" ],
      [ "tracto-technik", "TRACTO-TECHNIK", "Trenchless / Pipe Lining & Bursting" ],
      [ "tracto technik", "TRACTO-TECHNIK", "Trenchless / Pipe Lining & Bursting" ],
      [ "picote", "Picote", "Trenchless / Pipe Lining & Bursting" ],
      [ "electric eel", "Electric Eel", "Drain Cleaning Machines" ],
      [ "spartan drain", "Spartan Tool", "Drain Cleaning Machines" ],
      [ "general wire spring", "General Wire", "Drain Cleaning Machines" ],
      [ "ridgid drain", "RIDGID", "Drain Cleaning Machines" ],
      [ "ridgid k-", "RIDGID", "Drain Cleaning Machines" ]
    ]

    brands_by_category = Hash.new { |h, k| h[k] = [] }

    equipment_mappings.each do |term, brand, category|
      brands_by_category[category] << brand if lower_text.include?(term)
    end

    brands_by_category.each_value(&:uniq!)

    @extracted_data[:equipment_brands_list] = brands_by_category.any? ? brands_by_category : nil
  end

  def extract_services_list(lower_text) # rubocop:disable Metrics/MethodLength
    service_mappings = [
      [ "sewer camera inspection", "Sewer Camera Inspection", "Sewer Inspection" ],
      [ "camera inspection", "Camera Inspection", "Sewer Inspection" ],
      [ "sewer video inspection", "Sewer Video Inspection", "Sewer Inspection" ],
      [ "video pipe inspection", "Video Pipe Inspection", "Sewer Inspection" ],
      [ "cctv sewer inspection", "CCTV Sewer Inspection", "Sewer Inspection" ],
      [ "cctv pipe inspection", "CCTV Pipe Inspection", "Sewer Inspection" ],
      [ "pipe camera inspection", "Pipe Camera Inspection", "Sewer Inspection" ],
      [ "sewer scope inspection", "Sewer Scope Inspection", "Sewer Inspection" ],
      [ "sewer line inspection", "Sewer Line Inspection", "Sewer Inspection" ],
      [ "pipeline inspection", "Pipeline Inspection", "Sewer Inspection" ],
      [ "pipe inspection", "Pipe Inspection", "Sewer Inspection" ],
      [ "drain inspection", "Drain Inspection", "Sewer Inspection" ],
      [ "leak detection", "Leak Detection", "Sewer Inspection" ],
      [ "sewer leak detection", "Sewer Leak Detection", "Sewer Inspection" ],
      [ "plumbing leak detection", "Plumbing Leak Detection", "Sewer Inspection" ],
      [ "utility locating", "Utility Locating", "Sewer Inspection" ],
      [ "pipe locating", "Pipe Locating", "Sewer Inspection" ],
      [ "line locating", "Line Locating", "Sewer Inspection" ],
      [ "sewer locating", "Sewer Locating", "Sewer Inspection" ],
      [ "smoke testing", "Smoke Testing", "Sewer Inspection" ],
      [ "smoke test plumbing", "Smoke Test Plumbing", "Sewer Inspection" ],
      [ "smoke test sewer", "Smoke Test Sewer", "Sewer Inspection" ],
      [ "dye testing", "Dye Testing", "Sewer Inspection" ],
      [ "hydro jetting", "Hydro Jetting", "Sewer Maintenance" ],
      [ "hydro-jetting", "Hydro-Jetting", "Sewer Maintenance" ],
      [ "hydro jet drain cleaning", "Hydro Jet Drain Cleaning", "Sewer Maintenance" ],
      [ "sewer hydro jetting", "Sewer Hydro Jetting", "Sewer Maintenance" ],
      [ "high pressure water jetting", "High Pressure Water Jetting", "Sewer Maintenance" ],
      [ "water jetting", "Water Jetting", "Sewer Maintenance" ],
      [ "drain jetting", "Drain Jetting", "Sewer Maintenance" ],
      [ "sewer jetting", "Sewer Jetting", "Sewer Maintenance" ],
      [ "drain cleaning", "Drain Cleaning", "Sewer Maintenance" ],
      [ "drain clearing", "Drain Clearing", "Sewer Maintenance" ],
      [ "clogged drain", "Clogged Drain", "Sewer Maintenance" ],
      [ "blocked drain", "Blocked Drain", "Sewer Maintenance" ],
      [ "slow drain", "Slow Drain", "Sewer Maintenance" ],
      [ "drain unclogging", "Drain Unclogging", "Sewer Maintenance" ],
      [ "drain rodding", "Drain Rodding", "Sewer Maintenance" ],
      [ "mechanical drain cleaning", "Mechanical Drain Cleaning", "Sewer Maintenance" ],
      [ "sewer cleaning", "Sewer Cleaning", "Sewer Maintenance" ],
      [ "sewer line cleaning", "Sewer Line Cleaning", "Sewer Maintenance" ],
      [ "sewer maintenance", "Sewer Maintenance", "Sewer Maintenance" ],
      [ "sewer rodding", "Sewer Rodding", "Sewer Maintenance" ],
      [ "sewer flushing", "Sewer Flushing", "Sewer Maintenance" ],
      [ "root removal", "Root Removal", "Sewer Maintenance" ],
      [ "tree root removal", "Tree Root Removal", "Sewer Maintenance" ],
      [ "root intrusion removal", "Root Intrusion Removal", "Sewer Maintenance" ],
      [ "root cutting", "Root Cutting", "Sewer Maintenance" ],
      [ "sewer root cutting", "Sewer Root Cutting", "Sewer Maintenance" ],
      [ "pipe descaling", "Pipe Descaling", "Sewer Maintenance" ],
      [ "descaling pipes", "Descaling Pipes", "Sewer Maintenance" ],
      [ "chain knocking", "Chain Knocking", "Sewer Maintenance" ],
      [ "scale removal", "Scale Removal", "Sewer Maintenance" ],
      [ "pipe scaling removal", "Pipe Scaling Removal", "Sewer Maintenance" ],
      [ "sewer repair", "Sewer Repair", "Sewer Repair" ],
      [ "sewer line repair", "Sewer Line Repair", "Sewer Repair" ],
      [ "main sewer line repair", "Main Sewer Line Repair", "Sewer Repair" ],
      [ "pipe repair", "Pipe Repair", "Sewer Repair" ],
      [ "drain repair", "Drain Repair", "Sewer Repair" ],
      [ "broken sewer pipe repair", "Broken Sewer Pipe Repair", "Sewer Repair" ],
      [ "collapsed sewer repair", "Collapsed Sewer Repair", "Sewer Repair" ],
      [ "sewer pipe repair", "Sewer Pipe Repair", "Sewer Repair" ],
      [ "sewer replacement", "Sewer Replacement", "Sewer Repair" ],
      [ "sewer line replacement", "Sewer Line Replacement", "Sewer Repair" ],
      [ "pipe replacement", "Pipe Replacement", "Sewer Repair" ],
      [ "main sewer replacement", "Main Sewer Replacement", "Sewer Repair" ],
      [ "sewer pipe replacement", "Sewer Pipe Replacement", "Sewer Repair" ],
      [ "repiping", "Repiping", "Sewer Repair" ],
      [ "repipe", "Repipe", "Sewer Repair" ],
      [ "re-pipe", "Re-pipe", "Sewer Repair" ],
      [ "sewer excavation", "Sewer Excavation", "Sewer Repair" ],
      [ "open trench sewer repair", "Open Trench Sewer Repair", "Sewer Repair" ],
      [ "trench excavation", "Trench Excavation", "Sewer Repair" ],
      [ "dig and replace sewer", "Dig and Replace Sewer", "Sewer Repair" ],
      [ "yard sewer repair", "Yard Sewer Repair", "Sewer Repair" ],
      [ "underground pipe repair", "Underground Pipe Repair", "Sewer Repair" ],
      [ "trenchless sewer repair", "Trenchless Sewer Repair", "Trenchless Sewer Repair" ],
      [ "no dig sewer repair", "No Dig Sewer Repair", "Trenchless Sewer Repair" ],
      [ "trenchless pipe repair", "Trenchless Pipe Repair", "Trenchless Sewer Repair" ],
      [ "trenchless sewer replacement", "Trenchless Sewer Replacement", "Trenchless Sewer Repair" ],
      [ "pipe lining", "Pipe Lining", "Trenchless Sewer Repair" ],
      [ "pipe relining", "Pipe Relining", "Trenchless Sewer Repair" ],
      [ "sewer relining", "Sewer Relining", "Trenchless Sewer Repair" ],
      [ "epoxy pipe lining", "Epoxy Pipe Lining", "Trenchless Sewer Repair" ],
      [ "cipp lining", "CIPP Lining", "Trenchless Sewer Repair" ],
      [ "cured in place pipe", "Cured In Place Pipe", "Trenchless Sewer Repair" ],
      [ "cipp pipe lining", "CIPP Pipe Lining", "Trenchless Sewer Repair" ],
      [ "pipe rehabilitation", "Pipe Rehabilitation", "Trenchless Sewer Repair" ],
      [ "pipe bursting", "Pipe Bursting", "Trenchless Sewer Repair" ],
      [ "sewer pipe bursting", "Sewer Pipe Bursting", "Trenchless Sewer Repair" ],
      [ "trenchless pipe bursting", "Trenchless Pipe Bursting", "Trenchless Sewer Repair" ],
      [ "pipe bursting replacement", "Pipe Bursting Replacement", "Trenchless Sewer Repair" ]
    ]

    services_by_category = Hash.new { |h, k| h[k] = [] }

    service_mappings.each do |term, label, category|
      services_by_category[category] << label if lower_text.include?(term)
    end

    services_by_category.each_value(&:uniq!)

    @extracted_data[:services_list] = services_by_category.any? ? services_by_category : nil
    @extracted_data[:has_services] = services_by_category.any?
  end

  def extract_trenchless_technologies(lower_text)
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
      @extracted_data[:trenchless_technologies_list] << label if lower_text.include?(term)
    end
    @extracted_data[:trenchless_technologies_list].uniq!

    # Fallback logic if trenchless list is empty but text contains "sewer"
    if @extracted_data[:trenchless_technologies_list].empty? && lower_text.match?(/sewer|sewer line repair|sewer repair/)
      @extracted_data[:trenchless_technologies_list] << "Sewer Repair"
    end
  end

  def save_website_data
    WebsiteData.create(@extracted_data)
  end
end

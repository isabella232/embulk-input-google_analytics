require "tzinfo"
require "google/apis/analyticsreporting_v4"
require "google/apis/analytics_v3"

module Embulk
  module Input
    module GoogleAnalytics
      class Client
        attr_reader :task

        def initialize(task, is_preview = false)
          @task = task
          @is_preview = is_preview
        end

        def preview?
          @is_preview
        end

        def each_report_row(&block)
          page_token = nil
          timezone = get_profile_timezone
          Embulk.logger.info "view_id:#{view_id} timezone has been set as '#{timezone}'"

          loop do
            report = get_reports(page_token).to_h[:reports].first
            unless page_token
              # display for first request only
              Embulk.logger.info "Total: #{report[:data][:row_count]} rows. Fetched first response"
            end

            break if report[:data][:rows].empty?

            dimensions = report[:column_header][:dimensions]
            metrics = report[:column_header][:metric_header][:metric_header_entries].map{|m| m[:name]}
            report[:data][:rows].each do |row|
              dim = dimensions.zip(row[:dimensions]).to_h
              met = metrics.zip(row[:metrics].first[:values]).to_h
              format_row = dim.merge(met)
              format_row[task["time_series"]] += " #{timezone}" # we need to know which timezone's time value.
              block.call format_row
            end

            break if preview?

            unless page_token = report[:next_page_token]
              break
            end
            Embulk.logger.info "Fetching report with page_token: #{page_token}"
          end
        end

        def get_reports(page_token = nil)
          # https://developers.google.com/analytics/devguides/reporting/core/v4/rest/v4/reports/batchGet
          service = Google::Apis::AnalyticsreportingV4::AnalyticsReportingService.new
          service.authorization = auth

          request = Google::Apis::AnalyticsreportingV4::GetReportsRequest.new
          request.report_requests = build_report_request(page_token)
          service.batch_get_reports request
        end

        def get_columns_list
          # https://developers.google.com/analytics/devguides/reporting/metadata/v3/reference/metadata/columns/list
          service = Google::Apis::AnalyticsV3::AnalyticsService.new
          service.authorization = auth
          Embulk.logger.debug "Fetching columns info from API"
          service.list_metadata_columns("ga").to_h[:items]
        end

        def get_profile_timezone
          service = Google::Apis::AnalyticsV3::AnalyticsService.new
          service.authorization = auth

          Embulk.logger.debug "Fetching profile from API"
          profile = service.list_profiles("~all", "~all").to_h[:items].find do |prof|
            prof[:id] == view_id
          end
          unless profile
            raise Embulk::DataError.new("Can't find view_id:#{view_id} profile via Google Analytics API.")
          end

          timezone_abbr(profile[:timezone]) # e.g. PDT, JST, etc
        end

        def timezone_abbr(zone_name)
          tz = TZInfo::Timezone.get(zone_name)
          tz.period_for_utc(Time.now.utc).offset.abbreviation
        rescue TZInfo::InvalidTimezoneIdentifier => e
          raise Embulk::DataError.new("'#{zone_name}' is unknown time zone name.")
        end

        def build_report_request(page_token = nil)
          query = {
            view_id: view_id,
            dimensions: [{name: task["time_series"]}] + task["dimensions"].map{|d| {name: d}},
            metrics: task["metrics"].map{|m| {expression: m}},
            include_empty_rows: true,
            page_size: preview? ? 10 : 10000,
          }

          if task["start_date"] || task["end_date"]
            query[:date_ranges] = [{
              start_date: task["start_date"],
              end_date: task["end_date"],
            }]
          end

          if page_token
            query[:page_token] = page_token
          end

          [query]
        end

        def json_keyfile
          task["json_keyfile"]
        end

        def view_id
          task["view_id"]
        end

        def auth
          Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(json_keyfile),
            scope: "https://www.googleapis.com/auth/analytics.readonly"
          )
        end
      end
    end
  end
end

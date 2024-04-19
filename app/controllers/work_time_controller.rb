class WorkTimeController < ApplicationController
  unloadable
  #  before_filter :find_project, :authorize
  accept_api_auth :relay_total

  helper :custom_fields
  include CustomFieldsHelper

  NO_ORDER = -1

  def index
    @message = ""
    require_login || return
    @project = nil
    prepare_values
    hour_update
    make_pack
    set_holiday
    @custom_fields = TimeEntryCustomField.all
    @link_params.merge!(:action=>"index")
    if !params.key?(:user) then
      redirect_to @link_params
    else
      render "show"
    end
  end

  def show
    @message = ""
    require_login || return
    find_project
    authorize
    prepare_values
    if @this_user.nil? || !@this_user.allowed_to?(:view_work_time_tab, @project)
      @link_params.merge!(:action=>"relay_total")
      redirect_to @link_params
      return
    end
    hour_update
    make_pack
    set_holiday
    @custom_fields = TimeEntryCustomField.all
    @link_params.merge!(:action=>"show")
    if !params.key?(:user) then
      redirect_to @link_params
    end
  end

  def ajax_add_tickets_insert # Ajax action to insert into daily work time
    prepare_values

    uid = params[:user]
    @add_issue_id = params[:add_issue]
    @add_count = params[:count]
    if @this_uid==@crnt_uid then
      add_issue = Issue.find_by_id(@add_issue_id)
      @add_issue_children_cnt = Issue.where(["parent_id = ?", add_issue.id.to_s]).count
      if add_issue && add_issue.visible? then
        prj = add_issue.project
        if User.current.allowed_to?(:log_time, prj) then
          if add_issue.closed? then
            @issueHtml = "<del>"+add_issue.to_s+"</del>"
          else
            @issueHtml = add_issue.to_s
          end

          @activities = []
          @activity_default = nil
          prj.activities.each do |act|
            @activities.push([act.name, act.id])
            @activity_default = act.id if act.is_default
          end

          @custom_fields = TimeEntryCustomField.all
          @custom_fields.each do |cf|
            def cf.custom_field
              return self
            end
            def cf.value
              return self.default_value
            end
            def cf.true?
              return self.default_value
            end
          end

          @add_issue = add_issue
          @jobs = get_jobs_from_project_description(prj)

        end
      end
    end

    render(:layout=>false)
  end

  def register_project_settings
    @message = ""
    require_login || return
    find_project
    authorize
    @settings = Setting.plugin_redmine_work_time
    @settings = Hash.new unless @settings.is_a?(Hash)
    @settings['account_start_days'] = Hash.new unless @settings['account_start_days'].is_a?(Hash)
    @settings['account_start_days'][@project.id.to_s] = params['account_start_day']
    Setting.plugin_redmine_work_time = @settings
    redirect_to :controller => 'projects',
                :action => 'settings', :id => @project, :tab => 'work_time'
  end

private
  def find_project
    # Set @project as it seems to be required for Redmine Plugin
    @project = Project.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def prepare_values
    # ************************************* Value preparation
    @crnt_uid = User.current.id
    @this_uid = (params.key?(:user) && User.current.allowed_to?(:view_work_time_other_member, @project)) ? params[:user].to_i : @crnt_uid
    @this_user = User.find_by_id(@this_uid)

    if @project &&
      Setting.plugin_redmine_work_time.is_a?(Hash) &&
      Setting.plugin_redmine_work_time['account_start_days'].is_a?(Hash) &&
      Setting.plugin_redmine_work_time['account_start_days'].has_key?(@project.id.to_s)
        @account_start_day = Setting.plugin_redmine_work_time['account_start_days'][@project.id.to_s].to_i
    else
      @account_start_day = 1
    end

    @today = Date.today
    year = params.key?(:year) ? params[:year].to_i : @today.year
    month = params.key?(:month) ? params[:month].to_i : @today.month
    day = params.key?(:day) ? params[:day].to_i : @today.day
    @this_date = Date.new(year, month, day)
    display_date = @this_date
    display_date <<= 1 if day < @account_start_day
    @display_year = display_date.year
    @display_month = display_date.month

    @last_month = @this_date << 1
    @next_month = @this_date >> 1

    @restrict_project = (params.key?(:prj) && params[:prj].to_i > 0) ? params[:prj].to_i : false

    @first_date = Date.new(@display_year, @display_month, @account_start_day)
    @last_date = (@first_date >> 1) - 1

    @month_names = l(:wt_month_names).split(',')
    @wday_name = l(:wt_week_day_names).split(',')
    @wday_color = ["#faa", "#eee", "#eee", "#eee", "#eee", "#eee", "#aaf"]

    @link_params = {:controller=>"work_time", :id=>@project,
                    :year=>year, :month=>month, :day=>day,
                    :user=>@this_uid, :prj=>@restrict_project}
    @is_registerd_backlog = false
    begin
      Redmine::Plugin.find :redmine_backlogs
      @is_registerd_backlog = true
    rescue Exception => exception
    end
  end

  # Gets the jobs from the project description.
  def get_jobs_from_project_description(project)
    jobs = []

    # Available jobs are stored in the project description. Each job is on its own line and the line has to start with '- '.
    project.description.each_line do |line|
      if line.start_with?('- ')
        # The line consists of the job name and its description, both separated by a comma.
        # The job name is used as the value and the job description is used as the label.
        job_pair = line[2..-1].strip
        job, description = job_pair.split(',', 2).map(&:strip)
        # Description will consist of the job name followed by its description:
        description = "#{job} - #{description}"
        jobs.push([description, job])
      end
    end
    jobs # Return the list of job pairs [description, name]
  end

  def hour_update # Time entry update request processing
    by_other = false
    if @this_uid != @crnt_uid
      if User.current.allowed_to?(:edit_work_time_other_member, @project)
        by_other = true
      else
        return
      end
    end

    # Register new time entries
    if params["new_time_entry"] then
      params["new_time_entry"].each do |issue_id, valss|
        issue = Issue.find_by_id(issue_id)
        next if issue.nil? || !issue.visible?
        next if !User.current.allowed_to?(:log_time, issue.project)
        valss.each do |count, vals|
          tm_vals = vals.except "remaining_hours", "status_id"
          if params.has_key?("new_time_entry_#{issue_id}_#{count}")
            params["new_time_entry_#{issue_id}_#{count}"].each do |k, v|
              tm_vals[k] = v
            end
          end
          next if tm_vals["hours"].blank? && vals["remaining_hours"].blank? && vals["status_id"].blank?
          if tm_vals["hours"].present? then
            if !tm_vals[:activity_id] then
              append_error_message_html(@message, 'Error: Issue'+issue_id+': No Activities!')
              next
            end
            if by_other
              append_text = "\n[#{Time.now.localtime.strftime("%Y-%m-%d %H:%M")}] #{User.current.to_s}"
              append_text += " add time entry of ##{issue.id.to_s}: #{tm_vals[:hours].to_f}h"
            end
            new_entry = TimeEntry.new(:project => issue.project, :issue => issue, :author => User.current, :user => @this_user, :spent_on => @this_date)
            new_entry.safe_attributes = tm_vals
            # If tm_vals field contains job field, add it to the beginning of the comment
            if tm_vals.has_key?("job") && !tm_vals["job"].blank? then
              new_entry.comments = tm_vals["job"] + ", " + new_entry.comments
            end
            new_entry.save
            append_error_message_html(@message, hour_update_check_error(new_entry, issue_id))
          end
          if vals["remaining_hours"].present? || vals["status_id"].present? then
            append_error_message_html(@message, issue_update_to_remain_and_more(issue_id, vals))
          end
        end
      end
    end

    # Update existing time entries
    if params["time_entry"] then
      params["time_entry"].each do |id, vals|
        tm = TimeEntry.find_by_id(id)
        issue_id = tm.issue.id
        tm_vals = vals.except "remaining_hours", "status_id"
        if params.has_key?("time_entry_"+id.to_s)
          params["time_entry_"+id.to_s].each do |k,v|
            tm_vals[k] = v
          end
        end
        if tm_vals["hours"].blank? then
          # Delete time entry if hours field is empty
          if by_other
            append_text = "\n[#{Time.now.localtime.strftime("%Y-%m-%d %H:%M")}] #{User.current.to_s}"
            append_text += " delete time entry of ##{issue_id.to_s}: -#{tm.hours.to_f}h-"
          end
          tm.destroy
        else
          if by_other && tm_vals.key?(:hours) && tm.hours.to_f != tm_vals[:hours].to_f
            append_text = "\n[#{Time.now.localtime.strftime("%Y-%m-%d %H:%M")}] #{User.current.to_s}"
            append_text += " update time entry of ##{issue_id.to_s}: -#{tm.hours.to_f}h- #{tm_vals[:hours].to_f}h"
          end
          tm.safe_attributes = tm_vals
          # If tm_vals field contains job field, add it to the beginning of the comment
          if tm_vals.has_key?("job") && !tm_vals["job"].blank? then
            tm.comments = tm_vals["job"] + ", " + tm.comments
          end
          tm.save
          append_error_message_html(@message, hour_update_check_error(tm, issue_id))
        end
        if vals["remaining_hours"].present? || vals["status_id"].present? then
          append_error_message_html(@message, issue_update_to_remain_and_more(issue_id, vals))
        end
      end
    end
  end

  def issue_update_to_remain_and_more(issue_id, vals)
    issue = Issue.find_by_id(issue_id)
    return 'Error: Issue'+issue_id+': Private!' if issue.nil? || !issue.visible?
    return if vals["remaining_hours"].blank? && vals["status_id"].blank?
    journal = issue.init_journal(User.current)
    # update "0.0" is changed
    vals["remaining_hours"] = 0 if vals["remaining_hours"] == "0.0"
    if vals['status_id'] =~ /^M+(.*)$/
      vals['status_id'] = $1.to_i
    else
      vals.delete 'status_id'
    end
    issue.safe_attributes = vals
    return if !issue.changed?
    issue.save
    hour_update_check_error(issue, issue_id)
  end

  def append_error_message_html(html, msg)
    @message ||= ''
    @message += '<div style="background:#faa;">' + msg + '</div><br>' if !msg.blank?
  end

  def hour_update_check_error(obj, issue_id)
    return "" if obj.errors.empty?
    str = l("field_issue")+"#"+issue_id.to_s+"<br>"
    fm = obj.errors.full_messages
    fm.each do |msg|
        str += msg+"<br>"
    end
    str.html_safe
  end

  ################################ Set Holiday
  def set_holiday
    user_id = params["user"] || return
    if set_date = params['set_holiday'] then
      WtHolidays.create(:holiday=>set_date, :created_on=>Time.now, :created_by=>user_id)
    end
    if del_date = params['del_holiday'] then
      holidays = WtHolidays.where(["holiday=:h and deleted_on is null",{:h=>del_date}]).all
      holidays.each do |h|
        h.deleted_on = Time.now
        h.deleted_by = user_id
        h.save
      end
    end
  end

  def make_pack
    # Create data for monthly work time table
    @month_pack = {:ref_prjs=>{}, :odr_prjs=>[],
                   :total=>0, :total_by_day=>{},
                   :other=>0, :other_by_day=>{},
                   :count_prjs=>0, :count_issues=>0}
    @month_pack[:total_by_day].default = 0

    # Create data for daily work time table
    @day_pack = {:ref_prjs=>{}, :odr_prjs=>[],
                 :total=>0, :total_by_day=>{},
                 :other=>0, :other_by_day=>{},
                 :count_prjs=>0, :count_issues=>0}
    @day_pack[:total_by_day].default = 0

    # Aggregate work time for the month
    hours = TimeEntry.
        includes(:issue).
        where(["user_id=:uid and spent_on>=:day1 and spent_on<=:day2",
               {:uid => @this_uid, :day1 => @first_date, :day2 => @last_date}]).
        all
    hours.each do |hour|
      next if @restrict_project && @restrict_project!=hour.project.id
      work_time = hour.hours
      if hour.issue && hour.issue.visible? then
        # Check if the project is in the display items, if not, add it
        prj_pack = make_pack_prj(@month_pack, hour.project)

        # Check if the issue is in the display items, if not, add it
        issue_pack = make_pack_issue(prj_pack, hour.issue)

        issue_pack[:count_hours] += 1

        # Calculate total time
        @month_pack[:total] += work_time
        prj_pack[:total] += work_time
        issue_pack[:total] += work_time

        # Calculate total time by day
        date = hour.spent_on
        @month_pack[:total_by_day][date] += work_time
        prj_pack[:total_by_day][date] += work_time
        issue_pack[:total_by_day][date] += work_time

        if date==@this_date then # If it's the displayed date, add it to the daily pack
          # Check if the project is in the display items, if not, add it
          day_prj_pack = make_pack_prj(@day_pack, hour.project)

          # Check if the issue is in the display items, if not, add it
          day_issue_pack = make_pack_issue(day_prj_pack, hour.issue, NO_ORDER)

          day_issue_pack[:each_entries][hour.id] = hour # Add time entry
          day_issue_pack[:total] += work_time
          day_prj_pack[:total] += work_time
          @day_pack[:total] += work_time
        end
      else
        # Calculate total time
        @month_pack[:total] += work_time
        @month_pack[:other] += work_time

        # Calculate total time by day
        date = hour.spent_on
        @month_pack[:total_by_day][date] ||= 0
        @month_pack[:total_by_day][date] += work_time
        @month_pack[:other_by_day][date] ||= 0
        @month_pack[:other_by_day][date] += work_time

        if date==@this_date then # If it's the displayed date, add it to the daily pack
          @day_pack[:total] += work_time
          @day_pack[:other] += work_time
        end
      end
    end

    # List newly created tickets for this day
    next_date = @this_date+1
    t1 = Time.local(@this_date.year, @this_date.month, @this_date.day)
    t2 = Time.local(next_date.year, next_date.month, next_date.day)
    issues = Issue.where(["(author_id = :u and created_on >= :t1 and created_on < :t2) or "+
                              "id in (select journalized_id from journals where journalized_type = 'Issue' and "+
                              "user_id = :u and created_on >= :t1 and created_on < :t2 group by journalized_id)",
                          {:u => @this_user, :t1 => t1, :t2 => t2}]).all

    issues.each do |issue|
      next if @restrict_project && @restrict_project!=issue.project.id
      next if !@this_user.allowed_to?(:log_time, issue.project)
      next if !issue.visible?
      prj_pack = make_pack_prj(@day_pack, issue.project)
      issue_pack = make_pack_issue(prj_pack, issue)
      if issue_pack[:css_classes] == 'wt_iss_overdue'
        issue_pack[:css_classes] = 'wt_iss_overdue_worked'
      else
        issue_pack[:css_classes] = 'wt_iss_worked'
      end
    end
    issues = Issue.
        joins("INNER JOIN issue_statuses ist on ist.id = issues.status_id ").
        joins("LEFT JOIN groups_users on issues.assigned_to_id = group_id").
        joins("LEFT JOIN projects prj on issues.project_id = prj.id").
        where(["1 = 1 and
                (  (issues.assigned_to_id = :u or groups_users.user_id = :u) and
                   issues.start_date < :t2 and
                   ist.is_closed = :closed
                )", {:u => @this_uid, :t2 => t2, :closed => false}]).
        order("prj.name, issues.subject").
        all
    issues.each do |issue|
      next if @restrict_project && @restrict_project!=issue.project.id
      next if !@this_user.allowed_to?(:log_time, issue.project)
      next if !issue.visible?
      prj_pack = make_pack_prj(@day_pack, issue.project)
      issue_pack = make_pack_issue(prj_pack, issue)
      if issue_pack[:css_classes] == 'wt_iss_default'
        issue_pack[:css_classes] = 'wt_iss_assigned'
      elsif issue_pack[:css_classes] == 'wt_iss_worked'
        issue_pack[:css_classes] = 'wt_iss_assigned_worked'
      elsif issue_pack[:css_classes] == 'wt_iss_overdue'
        issue_pack[:css_classes] = 'wt_iss_assigned_overdue'
      elsif issue_pack[:css_classes] == 'wt_iss_overdue_worked'
        issue_pack[:css_classes] = 'wt_iss_assigned_overdue_worked'
      end
    end

    # Remove items with no work time from the monthly work time table and count the number of items
    @month_pack[:count_issues] = 0
    @month_pack[:odr_prjs].each do |prj_pack|
      prj_pack[:odr_issues].each do |issue_pack|
        if issue_pack[:count_hours]==0 then
          prj_pack[:count_issues] -= 1
        end
      end

      if prj_pack[:count_issues]==0 then
        @month_pack[:count_prjs] -= 1
      else
        @month_pack[:count_issues] += prj_pack[:count_issues]
      end
    end
  end

  def make_pack_prj(pack, new_prj, odr=NO_ORDER)
      # Check if the project is in the display items, if not, add it
      unless pack[:ref_prjs].has_key?(new_prj.id) then
        prj_pack = {:odr=>odr, :prj=>new_prj,
                    :total=>0, :total_by_day=>{},
                    :ref_issues=>{}, :odr_issues=>[], :count_issues=>0}
        pack[:ref_prjs][new_prj.id] = prj_pack
        pack[:odr_prjs].push prj_pack
        pack[:count_prjs] += 1
        prj_pack[:total_by_day].default = 0
        prj_pack[:jobs] = get_jobs_from_project_description(new_prj)
      end
      pack[:ref_prjs][new_prj.id]
  end

  def make_pack_issue(prj_pack, new_issue, odr=NO_ORDER)
      id = new_issue.nil? ? -1 : new_issue.id
      # Check if the issue is in the display items, if not, add it
      unless prj_pack[:ref_issues].has_key?(id) then
        issue_pack = {:odr=>odr, :issue=>new_issue,
                      :total=>0, :total_by_day=>{},
                      :count_hours=>0, :each_entries=>{},
                      :cnt_childrens=>0}
        issue_pack[:total_by_day].default = 0
        if !new_issue.due_date.nil? && new_issue.due_date < @this_date.to_datetime
          issue_pack[:css_classes] = 'wt_iss_overdue'
        else
          issue_pack[:css_classes] = 'wt_iss_default'
        end
        prj_pack[:ref_issues][id] = issue_pack
        prj_pack[:odr_issues].push issue_pack
        prj_pack[:count_issues] += 1
        cnt_childrens = Issue.where(["parent_id = ?", new_issue.id.to_s]).count
        issue_pack[:cnt_childrens] = cnt_childrens
      end
      prj_pack[:ref_issues][id]
  end

end

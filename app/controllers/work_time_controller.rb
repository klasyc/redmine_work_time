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
    member_add_del_check
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

          unless UserIssueMonth.exists?(["uid=:u and issue=:i",{:u=>uid, :i=>@add_issue_id}]) then
            # If there are no existing records, add a new one
            UserIssueMonth.create(:uid=>uid, :issue=>@add_issue_id,
              :odr => UserIssueMonth.where(["uid = ?", uid]).count + 1
            )
          end
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

  def member_add_del_check
    # Get project members
    mem = Member.where(["project_id=:prj", {:prj=>@project.id}]).all
    mem_by_uid = {}
    mem.each do |m|
      next if m.nil? || m.user.nil? || ! m.user.allowed_to?(:view_work_time_tab, @project)
      mem_by_uid[m.user_id] = m
    end

    # Get member positions
    odr = WtMemberOrder.where(["prj_id=:p", {:p=>@project.id}]).order("position").all

    # Get number of time entries per user for the current month
    entry_count = TimeEntry.
        where(["spent_on>=:first_date and spent_on<=:last_date",
               {:first_date=>@first_date, :last_date=>@last_date}]).
        select("user_id, count(hours)as cnt").
        group("user_id").
        all
    cnt_by_uid = {}
    entry_count.each do |ec|
      cnt_by_uid[ec.user_id] = ec.cnt
    end

    @members = []
    pos = 1
    # Check members that exist in the position information but not in the members list
    odr.each do |o|
      if mem_by_uid.has_key?(o.user_id) then
        user=mem_by_uid[o.user_id].user
        if ! user.nil? then
          # Check and fix position
          if o.position != pos then
            o.position=pos
            o.save
          end
          # Add member to the display list
          if user.active? || cnt_by_uid.has_key?(user.id) then
            @members.push([pos, user])
          end
          pos += 1
          # Remove member from the position information
          mem_by_uid.delete(o.user_id)
          next
        end
      end
      # メンバーに無い順序情報は削除する
      o.destroy
    end

    # 残ったメンバーを順序情報に加える
    mem_by_uid.each do |k,v|
      user = v.user
      next if user.nil?
      n = WtMemberOrder.new(:user_id=>user.id,
                              :position=>pos,
                              :prj_id=>@project.id)
      n.save
      if user.active? || cnt_by_uid.has_key?(user.id) then
        @members.push([pos, user])
      end
      pos += 1
    end

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

  def change_member_position
    ################################### Change member position
    if params.key?("member_pos") && params[:member_pos]=~/^(.*)_(.*)$/ then
      if User.current.allowed_to?(:edit_work_time_total, @project) then
        uid = $1.to_i
        dst = $2.to_i
        mem = WtMemberOrder.where(["prj_id=:p and user_id=:u",{:p=>@project.id, :u=>uid}]).first
        if mem then
          if mem.position > dst then # Move member forward
            tgts = WtMemberOrder.
                where(["prj_id=:p and position>=:p1 and position<:p2",{:p=>@project.id, :p1=>dst, :p2=>mem.position}]).
                all
            tgts.each do |mv|
              mv.position+=1; mv.save # Move position one by one forward
            end
            mem.position=dst; mem.save
          end
          if mem.position < dst then # Move member backward
            tgts = WtMemberOrder.
                where(["prj_id=:p and position<=:p1 and position>:p2",{:p=>@project.id, :p1=>dst, :p2=>mem.position}]).
                all
            tgts.each do |mv|
              mv.position-=1; mv.save # Move position one by one backward
            end
            mem.position=dst; mem.save
          end
        end
      else
        @message ||= ''
        @message += '<div style="background:#faa;">'+l(:wt_no_permission)+'</div>'
        return
      end
    end
  end

  def calc_total
    ################################################  Total calculation loop ########
    @total_cost = 0
    @member_cost = Hash.new
    WtMemberOrder.where(["prj_id=:p",{:p=>@project.id}]).all.each do |i|
      @member_cost[i.user_id] = 0
    end
    @issue_parent = Hash.new # clear cash

    @issue_cost = Hash.new
    @r_issue_cost = Hash.new

    @prj_cost = Hash.new
    @r_prj_cost = Hash.new

    @issue_act_cost = Hash.new
    @r_issue_act_cost = Hash.new

    relay = Hash.new
    WtTicketRelay.all.each do |i|
      relay[i.issue_id] = i.parent
    end

    # Extract time entries for the current month
    TimeEntry.
        where(["spent_on>=:t1 and spent_on<=:t2 and hours>0",{:t1 => @first_date, :t2 => @last_date}]).
        all.
        each do |time_entry|
      iid = time_entry.issue_id
      uid = time_entry.user_id
      cost = time_entry.hours
      act = time_entry.activity_id
      # Skip if it's not a time entry for a user in this project
      next unless @member_cost.key?(uid)

      issue = Issue.find_by_id(iid)
      next if issue.nil? # Skip if the issue has been deleted
      pid = issue.project_id
      # Skip if it's not a project-specific entry
      next if @restrict_project && pid != @restrict_project

      @total_cost += cost
      @member_cost[uid] += cost

      parent_iid = get_parent_issue(relay, iid)
      if !Issue.find_by_id(iid) || !Issue.find_by_id(iid).visible?
        # If the time entry is not visible, set the ids to -1
        iid = -1 # private
        pid = -1 # private
        act = -1 # private
      end
      @issue_cost[iid] ||= Hash.new
      @issue_cost[iid][-1] ||= 0
      @issue_cost[iid][-1] += cost
      @issue_cost[iid][uid] ||= 0
      @issue_cost[iid][uid] += cost

      @prj_cost[pid] ||= Hash.new
      @prj_cost[pid][-1] ||= 0
      @prj_cost[pid][-1] += cost
      @prj_cost[pid][uid] ||= 0
      @prj_cost[pid][uid] += cost

      @issue_act_cost[iid] ||= Hash.new
      @issue_act_cost[iid][uid] ||= Hash.new
      @issue_act_cost[iid][uid][act] ||= 0
      @issue_act_cost[iid][uid][act] += cost

      parent_issue = Issue.find_by_id(parent_iid)
      if parent_issue && parent_issue.visible?
        parent_pid = parent_issue.project_id
      else
        parent_iid = -1
        parent_pid = -1
      end

      @r_issue_cost[parent_iid] ||= Hash.new
      @r_issue_cost[parent_iid][-1] ||= 0
      @r_issue_cost[parent_iid][-1] += cost
      @r_issue_cost[parent_iid][uid] ||= 0
      @r_issue_cost[parent_iid][uid] += cost

      @r_prj_cost[parent_pid] ||= Hash.new
      @r_prj_cost[parent_pid][-1] ||= 0
      @r_prj_cost[parent_pid][-1] += cost
      @r_prj_cost[parent_pid][uid] ||= 0
      @r_prj_cost[parent_pid][uid] += cost

      @r_issue_act_cost[parent_iid] ||= Hash.new
      @r_issue_act_cost[parent_iid][uid] ||= Hash.new
      @r_issue_act_cost[parent_iid][uid][act] ||= 0
      @r_issue_act_cost[parent_iid][uid][act] += cost
    end
  end

  def get_parent_issue(relay, iid)
    @issue_parent ||= Hash.new
    return @issue_parent[iid] if @issue_parent.has_key?(iid)
    issue = Issue.find_by_id(iid)
    return 0 if issue.nil? # Return 0 if the issue has been deleted
    @issue_cost[iid] ||= Hash.new

    if relay.has_key?(iid)
      parent_id = relay[iid]
      if parent_id != 0 && parent_id != iid
        parent_id = get_parent_issue(relay, parent_id)
      end
      parent_id = iid if parent_id == 0
    else
      # If there is no relation, create one
      WtTicketRelay.create(:issue_id=>iid, :position=>relay.size, :parent=>0)
      parent_id = iid
    end

    # First processing for iid
    pid = issue.project_id
    unless @prj_cost.has_key?(pid)
      check = WtProjectOrders.where(["uid=-1 and dsp_prj=:p",{:p=>pid}]).all
      if check.size == 0
        WtProjectOrders.create(:uid=>-1, :dsp_prj=>pid, :dsp_pos=>@prj_cost.size)
      end
    end

    @issue_parent[iid] = parent_id # Return
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

  def sum_or_nil(v1, v2)
    if v2.blank?
      v1
    else
      if v1.blank?
        v2
      else
        v1 + v2
      end
    end
  end

end

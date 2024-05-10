//------------------------------------------------- for show.html.erb
var add_ticket_count = 1;

function dup_ticket(ajax_url, insert_pos, id)
{
  jQuery.ajax({
    url:ajax_url+"&add_issue="+id+"&count="+add_ticket_count,
    data:{asynchronous:true, method:'get'},
    success:function(response){
      jQuery('#'+insert_pos).after(response);
      // Let the newly added row pulse to indicate that it was added.
      var row = jQuery("#"+insert_pos).next();
      row.animate({backgroundColor: "#CCCCFF"}, 500);
      row.animate({backgroundColor: "#FAFAFA"}, 1000);
      // Install the mandatory select handlers again, because the new row has them.
      setTimeout(function() {
        install_mandatory_select_handlers();
      }, 100);
    }
  });
  add_ticket_count ++;
}

function statusUpdateOnDailyTable(name) {
  obj = document.getElementsByName(name)[0];
  obj.style.backgroundColor = '#cfc';
  index = obj.selectedIndex;
  v = obj.options[index].value;
  obj.options[index].value = 'M'+v;
}

// Hides projects that have no issues visible.
function set_project_visibility()
{
  // If the project is immediately followed by the next project, then it must be hidden and vice versa.
  $("#time_input_table tr.daily_report_project").each(function() {
    var project = $(this);
    var next = project.next();
    while (next.length > 0 && next.css("display") == "none") {
      next = next.next();
    }
    if (next.hasClass("daily_report_issue")) {
      project.show();
    } else {
      project.hide();
    }
  });
}

// Installs click handlers for the issue filtering radio buttons.
function install_filter_handlers()
{
  // Display all issues and projects:
  $("#filter_issues_all").click(function() {
    $("#time_input_table tr.daily_report_issue").show();
    set_project_visibility();
  });

  // Display issues already used in the monthly report.
  $("#filter_issues_month").click(function() {
    $("#time_input_table tr.daily_report_issue").each(function() {
      // Try to find the issue in the monthly report.
      // The issue id is stored in the data-issue attribute of the issues's hyperlink.
      var issue = $(this);
      var issue_id = issue.find("a.wt_iss_link").data("issue");

      // Now try to match the issue id with the monthly report.
      var monthlyLinks = $("#monthly_report").find("a.wt_iss_link[data-issue=" + issue_id + "]");
      if (monthlyLinks.length > 0) {
        issue.show();
      } else {
        issue.hide();
      }
    });

    // Call this method twice, otherwise the project visibility is not set correctly when
    // switching from filled to monthly issues.
    set_project_visibility();
    set_project_visibility();
  });

  // Display all issues which have hours filled in.
  $("#filter_issues_day").click(function() {
    $("#time_input_table tr.daily_report_issue").each(function() {
      const hoursInput = $(this).find("input.hours");
      if (hoursInput.length > 0) {
        if (hoursInput.first().val() == "") {
          $(this).hide();
        } else {
          $(this).show();
        }
      }
    });
    set_project_visibility();
  });
}

// If the row containing the hours input has a select element with class mandatory_select, then
// check if the select element has a value. If not, display the select element red and disable the Save button.
function check_row(row_element, enable_if_ok = true)
{
  var row = $(row_element).parents("tr");
  var row_ok = true;

  // Check if there is a value in the hours input field. If not, we can skip the rest.
  var hours = row.find("input.hours");
  if (hours.length == 0) {
    return;
  }
  var hours_value = hours.val().replace(",", ".");

  // If the value is not empty, try to parse it as a number.
  if (isNaN(Number(hours_value))) {
    row_ok = false;
    hours.css("background-color", "#FFCCCC");
  } else {
    hours.css("background-color", "");
  }

  // Check mandatory select elements, if they are present:
  var select = row.find("select.mandatory_select");
  if (select.length > 0) {
    var select_value = select.find(":selected");
    if (select_value.val() == "none" && hours_value != "") {
      row_ok = false;
      select.css("background-color", "#FFCCCC");
    } else {
      select.css("background-color", "");
    }
  }

  // Enable or disable the Save button, depending on the row status.
  if (enable_if_ok && row_ok) {
    $("#save_button").prop("disabled", false);
    // Now check all the rows, because some other row can be still invalid:
    $("#time_input_table tr input.hours").each(function() {
      check_row(this, false);
    });
  } else if (!row_ok) {
    $("#save_button").prop("disabled", true);
  }
}

// Installs change handlers on the input and select elements of the time input table.
// They allow to check if the select elements with class mandatory_select have a value.
function install_mandatory_select_handlers()
{
  $("#time_input_table tr input").on("input", function() {
    check_row(this);
  });
  $("#time_input_table tr select").on("change", function() {
    check_row(this);
  });
}

//------------- for user_day_table.html.erb
function sumDayTimes() {
  var total=0;
  var dayInputs;

  // List all Input elements of the page
  dayInputs = document.getElementsByTagName("input");
  for (var i=0; i<dayInputs.length; i++) {
    // Consider only those with an id containing the strings 'time_entry' and 'hours'
    if ((dayInputs[i].id.indexOf("time_entry") >= 0) && (dayInputs[i].id.indexOf("hours") >= 0)) {
      var val = dayInputs[i].value;
      if (val) {
        var vals = val.match(/^([\d\.]+)$/);
        if (vals) {
          // add the number to the total if it is a valid number
          total = total + parseFloat(vals[1]);
        }
        else {
          vals = val.match(/^(\d+)m$/);
          if(vals) {
            total = total + parseFloat(vals[1])/60;
          }
          else {
            vals = val.match(/^(\d+):(\d+)$/);
            if(vals) {
              total = total + parseFloat(vals[1]) + parseFloat(vals[2])/60;
            }
          }
        }
      }
    }
  }
  // Set the total value to the new number, changing the style to indicate 
  // it is not saved, and adding the saved value as a flyover indication
  var originalValue;
  document.getElementById("currentTotal").innerHTML = total.toFixed(2);
  document.getElementById("currentTotal").style = 'color:#FF0000;';
  return true;
}

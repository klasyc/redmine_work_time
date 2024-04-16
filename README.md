This is fork of the https://github.com/tkusukawa/redmine_work_time repository which contains a few modifications related to my company.
It is not intended as a continuation of the original project, but rather as a temporary solution to our needs.

WorkTime is a Redmine plugin to edit spent time by each user.

### Installation notes ###

* cd {RAILS_ROOT}/plugins
* git clone https://github.com/tkusukawa/redmine_work_time.git
* cd ../
* bundle exec rake redmine:plugins:migrate RAILS_ENV=production
* Restart Redmine
* Enable the module on the project setting page.
* Check the permissions on the Roles and permissions(Administration)

### Links ###

* http://www.redmine.org/plugins/redmine_work_time
* https://github.com/tkusukawa/redmine_work_time
* http://www.r-labs.org/projects/worktime/

begin;
create extension if not exists pg_cron;
-- One stable job name: repeated installation replaces the existing job.
select cron.schedule('mission-schedule-release','* * * * *','select private.run_schedule_releases()');
commit;

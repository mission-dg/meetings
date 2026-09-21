begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('shift-documents','shift-documents',false,10485760,array['application/pdf','text/plain','image/png','image/jpeg','application/vnd.openxmlformats-officedocument.wordprocessingml.document']) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create function private.document_file_access(p_path text,p_write boolean) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.document_versions f join private.documents d on d.id=f.document_id where f.path=p_path and case when p_write then private.is_manager() and f.created_by=auth.uid() and not f.ready and d.version=f.version and d.active else private.document_allowed(d.id) and f.ready and (private.is_manager() or d.active and d.version=f.version) end)
$$;
revoke all on function private.document_file_access(text,boolean) from public,anon;
grant execute on function private.document_file_access(text,boolean) to authenticated;
create policy shift_documents_read on storage.objects for select to authenticated using(bucket_id='shift-documents' and private.document_file_access(name,false));
create policy shift_documents_upload on storage.objects for insert to authenticated with check(bucket_id='shift-documents' and private.document_file_access(name,true));
create function public.document_ready(p_file uuid) returns void language plpgsql security definer set search_path='' as $$
declare f private.document_versions;
begin
 perform pg_advisory_xact_lock(61902028);
 select * into f from private.document_versions where id=p_file;
 if not private.is_manager() or f.id is null or f.created_by<>auth.uid() then raise exception 'File access denied';end if;
 if not exists(select 1 from storage.objects where bucket_id='shift-documents' and name=f.path) then raise exception 'Upload has not completed. Retry the upload';end if;
 if not exists(select 1 from private.documents where id=f.document_id and version=f.version and active) then raise exception 'A newer document version exists. Reload the library';end if;
 if not f.ready then
  update private.document_versions set ready=true where id=f.id;
  perform private.schedule_audit('document_published',f.document_id::text,null,jsonb_build_object('version',f.version,'filename',f.filename));
 end if;
end $$;
revoke all on function public.document_ready(uuid) from public,anon;
grant execute on function public.document_ready(uuid) to authenticated;
commit;

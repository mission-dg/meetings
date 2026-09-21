begin;
-- Export the complete directory, rather than just its current search/page.
create function public.directory_csv_export() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare page jsonb;items jsonb:='[]';offset_value int:=0;
begin
 if not (private.is_admin() or private.is_gm()) then raise exception 'GM or IT access required';end if;
 loop
  page:=public.operations_read('directory','manager',offset_value,'');
  items:=items||coalesce(page->'items','[]');
  exit when offset_value+50>=coalesce((page->>'total')::int,0) or jsonb_array_length(coalesce(page->'items','[]'))=0;
  offset_value:=offset_value+50;
 end loop;
 return coalesce((select jsonb_agg(jsonb_build_object('person_id',x->>'person_id','name',x->>'name','group',x->>'group','job',x->>'job','trainer',x->'trainer','phone',x->>'phone','email',x->>'email','version',coalesce((select c.version from private.person_contacts c where c.person_id=x->>'person_id'),0))) from jsonb_array_elements(items) x),'[]');
end $$;
revoke all on function public.directory_csv_export() from public,anon;
grant execute on function public.directory_csv_export() to authenticated;
commit;

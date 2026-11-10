-- Ejecutar completo en el SQL Editor del proyecto de Supabase.
-- No borra boletos ni apartados. Puede ejecutarse otra vez.
begin;

create or replace function public.es_administrador_rifa()
returns boolean language sql stable security invoker
set search_path = '' as $$
 select coalesce(auth.uid() in (
 'c14d812d-07e1-488a-8daa-94a0f1cbf299'::uuid,
 '9beb4c99-0906-493a-abe7-2da6151d2f93'::uuid), false);
$$;

-- Esta función solo puede ejecutarse internamente o desde el cron.
create or replace function public.liberar_apartados_vencidos()
returns integer language plpgsql security definer
set search_path = '' as $$
declare ids uuid[]; cantidad integer;
begin
 perform pg_catalog.pg_advisory_xact_lock(72419001);
 select array_agg(id) into ids from public.apartados
 where estado = 'apartado' and vence_en <= clock_timestamp();
 if ids is null then return 0; end if;
 update public.boletos b set estado = true
 from public.apartado_boletos ab
 where ab.apartado_id = any(ids) and ab.vigente and b.numero = ab.numero;
 update public.apartado_boletos set vigente = false
 where apartado_id = any(ids) and vigente;
 update public.apartados set estado = 'vencido' where id = any(ids);
 get diagnostics cantidad = row_count;
 return cantidad;
end;
$$;
revoke all on function public.liberar_apartados_vencidos() from public, anon, authenticated;

create or replace function public.admin_gestionar_apartado(p_id uuid, p_accion text)
returns jsonb language plpgsql security definer
set search_path = '' as $$
declare a public.apartados%rowtype; cantidad integer; vigentes integer;
begin
 if not public.es_administrador_rifa() then raise exception 'No autorizado.'; end if;
 if p_accion is null or p_accion not in ('confirmar_pago','cancelar') then raise exception 'Acción inválida.'; end if;
 perform pg_catalog.pg_advisory_xact_lock(72419001);
 -- Evita que un pago recibido fuera de plazo confirme números revendidos.
 select * into a from public.apartados where id = p_id for update;
 if not found then raise exception 'No existe el apartado.'; end if;
 if p_accion = 'confirmar_pago' and a.estado = 'pagado' then
   return jsonb_build_object('estado','pagado','mensaje','El pago ya estaba confirmado.');
 end if;
 if p_accion = 'cancelar' and a.estado = 'cancelado' then
   return jsonb_build_object('estado','cancelado','mensaje','El apartado ya estaba cancelado.');
 end if;
 if a.estado <> 'apartado' then raise exception 'Solo se pueden gestionar apartados pendientes. No se liberan boletos pagados.'; end if;
 if a.vence_en <= clock_timestamp() then
   perform public.liberar_apartados_vencidos();
   return jsonb_build_object('estado','vencido','mensaje','El apartado venció y sus números se liberaron. No se confirmó ningún pago.');
 end if;
 perform b.numero from public.boletos b join public.apartado_boletos ab on ab.numero=b.numero
 where ab.apartado_id=p_id order by b.numero for update of b;
 select count(*), count(*) filter (where vigente) into cantidad,vigentes
 from public.apartado_boletos where apartado_id=p_id;
 if cantidad=0 or cantidad<>vigentes then raise exception 'Los números del apartado ya no están reservados. Revisa el registro.'; end if;
 if p_accion='confirmar_pago' then
   update public.apartados set estado='pagado', pagado_en=clock_timestamp() where id=p_id;
   update public.boletos b set estado=false from public.apartado_boletos ab
   where ab.apartado_id=p_id and ab.vigente and b.numero=ab.numero;
   return jsonb_build_object('estado','pagado','mensaje','Pago confirmado. Los boletos permanecen ocupados.');
 else
   update public.boletos b set estado=true from public.apartado_boletos ab
   where ab.apartado_id=p_id and ab.vigente and b.numero=ab.numero;
   update public.apartado_boletos set vigente=false where apartado_id=p_id;
   update public.apartados set estado='cancelado', pagado_en=null where id=p_id;
   return jsonb_build_object('estado','cancelado','mensaje','Apartado cancelado y boletos liberados.');
 end if;
end;
$$;

create or replace function public.admin_listar_apartados(
 p_estado text default 'todos', p_busqueda text default '', p_offset integer default 0
)
returns jsonb language plpgsql security definer
set search_path = '' as $$
declare resultado jsonb; total bigint;
begin
 if not public.es_administrador_rifa() then raise exception 'No autorizado.'; end if;
 if p_estado is null or p_estado not in ('todos','apartado','pagado','cancelado','vencido') then raise exception 'Filtro inválido.'; end if;
 if p_offset is null or p_offset<0 then raise exception 'Página inválida.'; end if;
 perform pg_catalog.pg_advisory_xact_lock(72419001);
 perform public.liberar_apartados_vencidos();
 select count(*) into total from public.apartados a
 where (p_estado='todos' or a.estado=p_estado)
 and (coalesce(p_busqueda,'')='' or a.nombre ilike '%'||left(p_busqueda,150)||'%'
 or a.telefono ilike '%'||left(p_busqueda,150)||'%' or a.folio::text=trim(p_busqueda));
 select coalesce(jsonb_agg(to_jsonb(filas) order by filas.creado_en desc,filas.id), '[]'::jsonb)
 into resultado from (
 select a.id,a.folio,a.nombre,a.telefono,a.estado,a.creado_en,a.vence_en,a.pagado_en,
 a.token_consulta,a.precio_unitario,r.nombre as rifa,r.moneda,r.zona_horaria,
 (select coalesce(jsonb_agg(ab.numero order by ab.numero),'[]'::jsonb)
  from public.apartado_boletos ab where ab.apartado_id=a.id) as numeros,
 (select count(*)*a.precio_unitario from public.apartado_boletos ab where ab.apartado_id=a.id) as total
 from public.apartados a join public.rifas r on r.id=a.rifa_id
 where (p_estado='todos' or a.estado=p_estado)
 and (coalesce(p_busqueda,'')='' or a.nombre ilike '%'||left(p_busqueda,150)||'%'
 or a.telefono ilike '%'||left(p_busqueda,150)||'%' or a.folio::text=trim(p_busqueda))
 order by a.creado_en desc,a.id limit 25 offset p_offset
 ) filas;
 return jsonb_build_object('registros',resultado,'total',total);
end;
$$;

create or replace function public.admin_registrar_venta(
 p_rifa_id uuid,p_nombre text,p_telefono text,p_numeros bigint[],p_pagado boolean default false
)
returns jsonb language plpgsql security definer
set search_path = '' as $$
declare resultado jsonb; apartado uuid; gestion jsonb;
begin
 if not public.es_administrador_rifa() then raise exception 'No autorizado.'; end if;
 perform pg_catalog.pg_advisory_xact_lock(72419001);
 resultado:=public.apartar_boletos(p_rifa_id,p_nombre,p_telefono,p_numeros);
 if p_pagado then
  select id into apartado from public.apartados where token_consulta=(resultado->>'token')::uuid;
  gestion:=public.admin_gestionar_apartado(apartado,'confirmar_pago');
  if gestion->>'estado'<>'pagado' then raise exception 'No fue posible confirmar la venta. No se guardó el registro.'; end if;
  resultado:=resultado||jsonb_build_object('estado','pagado');
 end if;
 return resultado;
end;
$$;

revoke all on function public.es_administrador_rifa() from public,anon;
grant execute on function public.es_administrador_rifa() to authenticated;
revoke all on function public.admin_gestionar_apartado(uuid,text) from public,anon;
revoke all on function public.admin_listar_apartados(text,text,integer) from public,anon;
revoke all on function public.admin_registrar_venta(uuid,text,text,bigint[],boolean) from public,anon;
grant execute on function public.admin_gestionar_apartado(uuid,text) to authenticated;
grant execute on function public.admin_listar_apartados(text,text,integer) to authenticated;
grant execute on function public.admin_registrar_venta(uuid,text,text,bigint[],boolean) to authenticated;

-- Cron de Supabase: libera los vencidos cada minuto, aunque nadie visite la página.
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule(
 'rifa-liberar-vencidos',
 '* * * * *',
 'select public.liberar_apartados_vencidos();'
);

commit;

-- Verificación: debe mostrar el trabajo con active = true.
select jobname, schedule, active
from cron.job where jobname='rifa-liberar-vencidos';

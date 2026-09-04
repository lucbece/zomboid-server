"""Los tres comandos, con OCI y A2S falsos y un reloj que se adelanta solo.

Lo que se verifica es la parte que no se puede probar contra el server real sin apagarlo: que
/pz start siga el arranque hasta que el juego contesta, y sobre todo que /pz stop NO apague
nunca con gente adentro ni cuando no se puede saber si la hay.
"""

import json
import tempfile
import unittest
from pathlib import Path

from logica import (
    EstadoBot,
    accion_start,
    accion_status,
    accion_stop,
    duracion_legible,
    ids_desde_env,
    puede_apagar,
    puede_usar,
)
from tests.dobles import A2SFalso, OCIFalso, Reloj, contexto, recolectar


class TestStart(unittest.IsolatedAsyncioTestCase):
    async def test_prende_una_vm_apagada_y_espera_al_juego(self):
        reloj = Reloj()
        oci = OCIFalso(["STOPPED"])
        # El juego contesta recien a los 100 s simulados.
        sonda = A2SFalso(reloj, responde_desde=100)
        ctx = contexto(oci, sonda, reloj, intervalo=10, espera_maxima=420)

        pasos = await recolectar(accion_start(ctx))

        self.assertEqual(oci.arrancadas, 1)
        self.assertIn("tarda ~3 minutos", pasos[0])
        self.assertTrue(any("Prendiendo el server…" in p for p in pasos[1:-1]))
        self.assertIn("En línea", pasos[-1])
        self.assertIn("PandaParkour", pasos[-1])
        self.assertIn("203.0.113.10:16261", pasos[-1])
        # Y queda registrado el momento del arranque, sin el ~ de "aproximado".
        self.assertIsNotNone(ctx.estado.encendida_desde)
        self.assertFalse(ctx.estado.aproximado)

    async def test_si_ya_esta_en_linea_lo_dice_y_no_toca_nada(self):
        reloj = Reloj()
        oci = OCIFalso(["RUNNING"])
        sonda = A2SFalso(reloj, responde_desde=0, jugadores=3)
        pasos = await recolectar(accion_start(contexto(oci, sonda, reloj)))

        self.assertEqual(len(pasos), 1)
        self.assertIn("Ya está en línea", pasos[0])
        self.assertIn("3 jugadores", pasos[0])
        self.assertEqual(oci.arrancadas, 0)

    async def test_vm_encendida_con_el_juego_todavia_cargando(self):
        reloj = Reloj()
        oci = OCIFalso(["RUNNING"])
        sonda = A2SFalso(reloj, responde_desde=60)
        ctx = contexto(oci, sonda, reloj, intervalo=10, espera_maxima=300)
        pasos = await recolectar(accion_start(ctx))

        self.assertEqual(oci.arrancadas, 0)  # no se manda START a algo que ya corre
        self.assertIn("todavía no responde", pasos[0])
        self.assertIn("En línea", pasos[-1])

    async def test_mientras_se_esta_prendiendo_no_se_manda_otro_start(self):
        reloj = Reloj()
        oci = OCIFalso(["STARTING"])
        sonda = A2SFalso(reloj, responde_desde=30)
        pasos = await recolectar(accion_start(contexto(oci, sonda, reloj, intervalo=10)))

        self.assertEqual(oci.arrancadas, 0)
        self.assertIn("ya se está prendiendo", pasos[0])

    async def test_mientras_se_apaga_no_hace_nada(self):
        reloj = Reloj()
        oci = OCIFalso(["STOPPING"])
        pasos = await recolectar(accion_start(
            contexto(oci, A2SFalso(reloj), reloj)))

        self.assertEqual(len(pasos), 1)
        self.assertIn("se está apagando", pasos[0])
        self.assertEqual(oci.arrancadas, 0)

    async def test_si_el_juego_no_levanta_lo_dice_en_vez_de_colgarse(self):
        reloj = Reloj()
        oci = OCIFalso(["STOPPED"])
        sonda = A2SFalso(reloj, responde_desde=None)  # nunca contesta
        ctx = contexto(oci, sonda, reloj, intervalo=10, espera_maxima=60)
        pasos = await recolectar(accion_start(ctx))

        self.assertIn("no respondió", pasos[-1])
        self.assertIn("/pz status", pasos[-1])

    async def test_error_de_oci_se_cuenta_en_castellano(self):
        reloj = Reloj()
        oci = OCIFalso(["STOPPED"], falla_en={"estado"})
        pasos = await recolectar(accion_start(contexto(oci, A2SFalso(reloj), reloj)))

        self.assertEqual(len(pasos), 1)
        self.assertIn("No se pudo consultar el estado", pasos[0])

    async def test_error_al_mandar_el_start(self):
        reloj = Reloj()
        oci = OCIFalso(["STOPPED"], falla_en={"arrancar"})
        pasos = await recolectar(accion_start(contexto(oci, A2SFalso(reloj), reloj)))

        self.assertIn("No se pudo prender el server", pasos[-1])


class TestStatus(unittest.IsolatedAsyncioTestCase):
    async def test_vm_apagada(self):
        reloj = Reloj()
        pasos = await recolectar(accion_status(
            contexto(OCIFalso(["STOPPED"]), A2SFalso(reloj), reloj)))
        self.assertIn("apagada", pasos[0])
        self.assertIn("/pz start", pasos[0])

    async def test_en_linea_muestra_lo_que_dice_el_server(self):
        reloj = Reloj()
        sonda = A2SFalso(reloj, responde_desde=0, jugadores=2)
        ctx = contexto(OCIFalso(["RUNNING"]), sonda, reloj)
        ctx.estado.marcar_encendida(0.0, aproximado=False)
        reloj.t = 3600 + 900  # 1 h 15 min encendida

        pasos = await recolectar(accion_status(ctx))

        # El nombre y el mapa salen del propio A2S, no estan hardcodeados en el bot.
        self.assertIn("PandaParkour", pasos[0])
        self.assertIn("Muldraugh, KY", pasos[0])
        self.assertIn("2 jugadores de 16", pasos[0])
        self.assertIn("versión 42.20", pasos[0])
        self.assertIn("Encendido hace 1 h 15 min", pasos[0])

    async def test_vm_arriba_pero_el_juego_no_contesta(self):
        reloj = Reloj()
        pasos = await recolectar(accion_status(
            contexto(OCIFalso(["RUNNING"]), A2SFalso(reloj, responde_desde=None), reloj)))
        self.assertIn("cargando los mods", pasos[0])


class TestStop(unittest.IsolatedAsyncioTestCase):
    async def test_con_jugadores_no_apaga(self):
        reloj = Reloj()
        oci = OCIFalso(["RUNNING"])
        sonda = A2SFalso(reloj, responde_desde=0, jugadores=2)
        pasos = await recolectar(accion_stop(contexto(oci, sonda, reloj)))

        self.assertEqual(oci.apagadas, 0)
        self.assertIn("2 jugadores", pasos[0])
        self.assertIn("no se apaga", pasos[0])

    async def test_sin_jugadores_apaga(self):
        reloj = Reloj()
        oci = OCIFalso(["RUNNING"])
        sonda = A2SFalso(reloj, responde_desde=0, jugadores=0)
        ctx = contexto(oci, sonda, reloj)
        ctx.estado.marcar_encendida(0.0)
        pasos = await recolectar(accion_stop(ctx))

        self.assertEqual(oci.apagadas, 1)
        self.assertIn("Sin jugadores", pasos[0])
        self.assertIn("guarda la partida", pasos[-1])
        self.assertIsNone(ctx.estado.encendida_desde)

    async def test_si_a2s_no_contesta_no_apaga_a_ciegas(self):
        # El caso peligroso: la VM esta RUNNING pero el juego no responde. Podria ser que
        # este cargando con gente esperando para entrar; no hay forma de saberlo, no se apaga.
        reloj = Reloj()
        oci = OCIFalso(["RUNNING"])
        pasos = await recolectar(accion_stop(
            contexto(oci, A2SFalso(reloj, responde_desde=None), reloj)))

        self.assertEqual(oci.apagadas, 0)
        self.assertIn("no se puede saber si hay gente", pasos[0])

    async def test_sin_permiso_no_consulta_ni_apaga(self):
        reloj = Reloj()
        oci = OCIFalso(["RUNNING"])
        pasos = await recolectar(accion_stop(
            contexto(oci, A2SFalso(reloj, responde_desde=0), reloj), autorizado=False))

        self.assertEqual(oci.apagadas, 0)
        self.assertEqual(oci.llamadas_estado, 0)
        self.assertIn("admins", pasos[0])

    async def test_ya_apagada(self):
        reloj = Reloj()
        oci = OCIFalso(["STOPPED"])
        pasos = await recolectar(accion_stop(contexto(oci, A2SFalso(reloj), reloj)))
        self.assertEqual(oci.apagadas, 0)
        self.assertIn("ya está apagado", pasos[0])

    async def test_error_al_apagar(self):
        reloj = Reloj()
        oci = OCIFalso(["RUNNING"], falla_en={"apagar"})
        sonda = A2SFalso(reloj, responde_desde=0, jugadores=0)
        pasos = await recolectar(accion_stop(contexto(oci, sonda, reloj)))
        self.assertIn("No se pudo apagar", pasos[-1])


class TestAutorizacion(unittest.TestCase):
    def test_sin_admins_configurados_puede_cualquiera(self):
        self.assertTrue(puede_apagar(1, []))

    def test_con_admins_solo_ellos(self):
        self.assertTrue(puede_apagar(10, [10, 20]))
        self.assertFalse(puede_apagar(30, [10, 20]))

    def test_roles(self):
        self.assertTrue(puede_usar([], []))
        self.assertTrue(puede_usar([5], [5, 6]))
        self.assertFalse(puede_usar([7], [5, 6]))

    def test_ids_desde_env(self):
        self.assertEqual(ids_desde_env("10, 20;30"), [10, 20, 30])
        self.assertEqual(ids_desde_env(""), [])
        self.assertEqual(ids_desde_env("  "), [])
        self.assertEqual(ids_desde_env("no-es-un-id, 42"), [42])


class TestEstadoBot(unittest.TestCase):
    def test_persiste_entre_reinicios(self):
        with tempfile.TemporaryDirectory() as tmp:
            ruta = Path(tmp) / "sub" / "estado.json"
            e = EstadoBot(ruta=ruta)
            e.marcar_encendida(123.0, aproximado=False)
            self.assertEqual(json.loads(ruta.read_text())["encendida_desde"], 123.0)

            otro = EstadoBot(ruta=ruta).cargar()
            self.assertEqual(otro.encendida_desde, 123.0)
            self.assertFalse(otro.aproximado)

    def test_una_observacion_aproximada_no_pisa_un_arranque_real(self):
        e = EstadoBot(ruta=None)
        e.marcar_encendida(100.0, aproximado=False)
        e.marcar_encendida(500.0, aproximado=True)
        self.assertEqual(e.encendida_desde, 100.0)

    def test_archivo_ilegible_no_rompe_nada(self):
        with tempfile.TemporaryDirectory() as tmp:
            ruta = Path(tmp) / "estado.json"
            ruta.write_text("{ esto no es json")
            e = EstadoBot(ruta=ruta).cargar()
            self.assertIsNone(e.encendida_desde)


class TestDuracion(unittest.TestCase):
    def test_formatos(self):
        self.assertEqual(duracion_legible(0), "0 min")
        self.assertEqual(duracion_legible(59), "0 min")
        self.assertEqual(duracion_legible(60), "1 min")
        self.assertEqual(duracion_legible(3600), "1 h 0 min")
        self.assertEqual(duracion_legible(3600 * 25), "1 d 1 h")


if __name__ == "__main__":
    unittest.main()

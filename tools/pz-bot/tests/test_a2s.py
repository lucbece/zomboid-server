"""El parser A2S, probado contra una respuesta real del server (B42 42.20.4).

tests/fixtures/a2s_info.bin es el datagrama que devolvio el server de verdad, byte por byte,
con el unico cambio de poner en cero el SteamID de la instalacion (no se commitean
identificadores reales). Es la parte del bot que depende de un formato ajeno: si Project
Zomboid cambia como arma la respuesta, /pz start deja de detectar que el juego levanto.
"""

import socket
import unittest
from pathlib import Path

import a2s

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "a2s_info.bin"
CHALLENGE = b"\xff\xff\xff\xffA\xe2\xef\xd4\x99"


class TestParseo(unittest.TestCase):
    def setUp(self):
        self.datos = FIXTURE.read_bytes()

    def test_respuesta_real(self):
        info = a2s.parsear_info(self.datos)
        self.assertEqual(info.nombre, "PandaParkour")
        self.assertEqual(info.mapa, "Muldraugh, KY")
        self.assertEqual(info.juego, "Project Zomboid")
        self.assertEqual(info.max_jugadores, 16)
        self.assertGreaterEqual(info.jugadores, 0)
        self.assertEqual(info.puerto, 16261)
        self.assertIn("VERSION:42.20", info.etiquetas)

    def test_la_version_sale_de_las_keywords(self):
        # El campo `version` del protocolo lo llena PZ con '1.0.0.0' siempre: la version util
        # es la de las keywords. Si se leyera el campo version, el mensaje diria "1.0.0.0".
        info = a2s.parsear_info(self.datos)
        self.assertEqual(info.version, "1.0.0.0")
        self.assertEqual(info.version_juego, "42.20")

    def test_sin_keywords_cae_al_campo_version(self):
        info = a2s.InfoServidor("n", "m", "j", 0, 16, "1.2.3", etiquetas="")
        self.assertEqual(info.version_juego, "1.2.3")

    def test_respuesta_truncada(self):
        with self.assertRaises(a2s.ErrorA2S):
            a2s.parsear_info(self.datos[:20])

    def test_cabecera_ajena(self):
        with self.assertRaises(a2s.ErrorA2S):
            a2s.parsear_info(b"cualquier cosa")

    def test_tipo_inesperado(self):
        with self.assertRaises(a2s.ErrorA2S):
            a2s.parsear_info(CHALLENGE)

    def test_es_challenge(self):
        self.assertEqual(a2s.es_challenge(CHALLENGE), b"\xe2\xef\xd4\x99")
        self.assertIsNone(a2s.es_challenge(self.datos))
        self.assertIsNone(a2s.es_challenge(b""))


class TestConsulta(unittest.TestCase):
    """El ida y vuelta del challenge, con un transporte falso en vez de un socket."""

    def setUp(self):
        self.info = FIXTURE.read_bytes()
        self.enviados = []

    def _transporte(self, guion):
        respuestas = list(guion)

        def enviar(datos):
            self.enviados.append(datos)
            siguiente = respuestas.pop(0)
            if isinstance(siguiente, Exception):
                raise siguiente
            return siguiente

        return enviar

    def test_resuelve_el_challenge(self):
        info = a2s.consultar("203.0.113.10", 16261,
                             transporte=self._transporte([CHALLENGE, self.info]))
        self.assertEqual(info.nombre, "PandaParkour")
        self.assertEqual(len(self.enviados), 2)
        self.assertEqual(self.enviados[0], a2s.PEDIDO)
        # El segundo pedido es el mismo con los cuatro bytes del challenge pegados al final.
        self.assertEqual(self.enviados[1], a2s.PEDIDO + b"\xe2\xef\xd4\x99")

    def test_sin_challenge_tambien_funciona(self):
        info = a2s.consultar("203.0.113.10", transporte=self._transporte([self.info]))
        self.assertEqual(info.max_jugadores, 16)
        self.assertEqual(len(self.enviados), 1)

    def test_timeout_es_sin_respuesta(self):
        guion = [socket.timeout("agotado")] * 6
        with self.assertRaises(a2s.SinRespuesta):
            a2s.consultar("203.0.113.10", transporte=self._transporte(guion))
        self.assertEqual(len(self.enviados), 3)  # tres intentos

    def test_reintenta_despues_de_una_perdida(self):
        # Primer intento: se pierde el datagrama con el challenge resuelto y vuelve otro
        # challenge. El segundo intento arranca de cero y funciona.
        guion = [CHALLENGE, CHALLENGE, CHALLENGE, self.info]
        info = a2s.consultar("203.0.113.10", transporte=self._transporte(guion))
        self.assertEqual(info.nombre, "PandaParkour")

    def test_consultar_o_none(self):
        self.assertIsNone(a2s.consultar_o_none(
            "203.0.113.10", transporte=self._transporte([socket.timeout()] * 6)))
        self.assertIsNotNone(a2s.consultar_o_none(
            "203.0.113.10", transporte=self._transporte([self.info])))


if __name__ == "__main__":
    unittest.main()

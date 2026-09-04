"""Reintentos y traduccion de errores del cliente de OCI, sin el SDK instalado.

ClienteInstancia importa `oci` en el constructor, asi que aca se instancia sin pasar por el
(object.__new__) y se le enchufa un compute falso: lo que se prueba es la politica de
reintentos, que es lo que decide si un error de red se le muestra o no a la gente.
"""

import unittest

import power


class ErrorServicio(Exception):
    """Imita oci.exceptions.ServiceError: trae status, code y message."""

    def __init__(self, status, code="", message=""):
        super().__init__(message or code)
        self.status = status
        self.code = code
        self.message = message


class ComputeFalso:
    def __init__(self, guion):
        self.guion = list(guion)
        self.acciones = []

    def _siguiente(self):
        r = self.guion.pop(0)
        if isinstance(r, Exception):
            raise r
        return r

    def get_instance(self, ocid):
        self.acciones.append(("get", ocid))
        return self._siguiente()

    def instance_action(self, ocid, accion):
        self.acciones.append((accion, ocid))
        return self._siguiente()


class Respuesta:
    def __init__(self, estado):
        self.data = type("Datos", (), {"lifecycle_state": estado})()


def cliente(guion):
    """ClienteInstancia sin pasar por __init__ (que importaria el SDK de OCI)."""
    c = object.__new__(power.ClienteInstancia)
    c.instance_ocid = "ocid1.instance.oc1..ejemplo"
    c._compute = ComputeFalso(guion)
    c._dormir = lambda _s: None
    return c


class TestCliente(unittest.TestCase):
    def test_estado(self):
        c = cliente([Respuesta("RUNNING")])
        self.assertEqual(c.estado(), "RUNNING")

    def test_arrancar_manda_start(self):
        c = cliente([None])
        c.arrancar()
        self.assertEqual(c._compute.acciones, [("START", c.instance_ocid)])

    def test_apagar_manda_softstop_no_stop(self):
        # SOFTSTOP dispara el shutdown del SO y con el el ExecStop de zomboid.service
        # (RCON save + quit). STOP seria tirar del cable con el mundo sin guardar.
        c = cliente([None])
        c.apagar()
        self.assertEqual(c._compute.acciones, [("SOFTSTOP", c.instance_ocid)])

    def test_reintenta_un_error_transitorio(self):
        c = cliente([ErrorServicio(500, "InternalError"), Respuesta("STOPPED")])
        self.assertEqual(c.estado(), "STOPPED")
        self.assertEqual(len(c._compute.acciones), 2)

    def test_no_reintenta_un_404(self):
        c = cliente([ErrorServicio(404, "NotAuthorizedOrNotFound")] * 3)
        with self.assertRaises(power.ErrorOCI) as ctx:
            c.estado()
        self.assertIn("no encuentra la instancia", str(ctx.exception))
        self.assertEqual(len(c._compute.acciones), 1)

    def test_un_429_si_se_reintenta(self):
        c = cliente([ErrorServicio(429, "TooManyRequests"), Respuesta("RUNNING")])
        self.assertEqual(c.estado(), "RUNNING")

    def test_se_queda_sin_reintentos(self):
        c = cliente([ErrorServicio(500)] * 3)
        with self.assertRaises(power.ErrorOCI):
            c.estado()
        self.assertEqual(len(c._compute.acciones), 3)


class TestMensajes(unittest.TestCase):
    def test_403_habla_de_la_policy(self):
        self.assertIn("dynamic group", power._mensaje_de_error(ErrorServicio(403)))

    def test_409_sugiere_esperar(self):
        self.assertIn("transición", power._mensaje_de_error(ErrorServicio(409)))

    def test_error_sin_status(self):
        self.assertIn("No se pudo hablar con OCI",
                      power._mensaje_de_error(RuntimeError("se cayo la red")))

    def test_estado_legible(self):
        self.assertEqual(power.estado_legible("RUNNING"), "encendida")
        self.assertEqual(power.estado_legible("STOPPED"), "apagada")
        self.assertEqual(power.estado_legible("ALGO_RARO"), "algo raro")


if __name__ == "__main__":
    unittest.main()

# Reglas extra cuando te pregunta una persona

Este texto se suma a las reglas del auto-arreglo cuando te invoca `scripts/ask.sh`, que es la
puerta por la que el bot de Discord te trae una pregunta dicha en voz alta. Todo lo de
`tools/autorepair/CLAUDE.md` sigue valiendo: lo prohibido sigue prohibido, los limites siguen
siendo los mismos.

Lo que cambia es que **hay alguien despierto del otro lado**.

## Que significa eso

El auto-arreglo corre a las tres de la mañana sin nadie a quien preguntarle, y por eso actua:
mas vale un reinicio de mas que un server caido hasta el mediodia. Aca es al reves. La persona
que pregunta esta en una llamada, ahora, y te puede contestar en cinco segundos.

- **Ante la duda, preguntá en vez de actuar.** Si hay dos causas posibles, decí cuales son y
  cual mirarias primero. No elijas por tu cuenta cuando elegir mal cuesta una partida.
- **Si te piden algo que toca a todos, decilo antes de hacerlo.** Reiniciar saca a los que estan
  jugando; desactivar un mod le cambia la partida a los dieciseis. Si nadie te dijo que hay
  gente conectada, fijate vos antes.
- **Lo que te pidieron es lo que hacés.** No aproveches el viaje para arreglar otras tres cosas
  que viste de paso: mencionalas en el informe y que decidan ellos.

## Como contestar

Tu respuesta se lee en voz alta en una llamada. Terminá **siempre** con un bloque JSON, solo,
en la ultima linea, con esta forma exacta:

```json
{"spoken": "una sola frase, hablada, en español rioplatense", "detail": "el informe completo, markdown, todo lo largo que haga falta"}
```

- `spoken` es lo unico que se dice. Una frase. Sin numeros de linea, sin rutas, sin nombres de
  archivo, sin leer el log. Lo que una persona le diria a otra cruzando la puerta: "el server
  esta arriba, se cayo por un mod que falta". Si hay detalle, terminá con "te lo dejo escrito".
- `detail` es lo que se escribe en el canal de texto. Ahi si va todo: que miraste, que
  encontraste, que cambiaste, que queda pendiente.
- Si no pudiste, `spoken` lo dice en una frase y `detail` explica por que. Un "no pude" honesto
  vale mas que un intento a ciegas.

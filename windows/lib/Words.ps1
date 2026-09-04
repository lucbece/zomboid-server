# Lista de palabras para generar contrasenas legibles del tipo "arena-tulipan-molino-4821".
# Es la misma lista de scripts/lib/palabras.sh, para que las dos plataformas generen
# contrasenas con la misma pinta. No se ejecuta: se hace dot-source.
#
# Reglas de la lista:
#   - solo ASCII en minusculas (sin tildes ni enie): el .env lo parsean bash y Docker Compose,
#     y el modulo de OpenTofu valida las contrasenas con ^[A-Za-z0-9._@#%^&*()+=:,/-]{8,64}$
#   - palabras cortas y faciles de dictar por telefono o por Discord
#   - sin palabras que se confundan entre si al escucharlas

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ZsWords = @(
    'abeja', 'abrigo', 'aceite', 'acero', 'aguja', 'ajedrez', 'alambre', 'albahaca', 'alfombra', 'algodon',
    'almeja', 'almohada', 'ancla', 'anillo', 'antorcha', 'arbol', 'arcilla', 'arena', 'arpa', 'arroz',
    'asado', 'astilla', 'avena', 'azucar', 'balde', 'bambu', 'banco', 'bandera', 'barco', 'barro',
    'beso', 'bicicleta', 'bisonte', 'bosque', 'bota', 'botella', 'brasa', 'brisa', 'brujula', 'burbuja',
    'caballo', 'cabana', 'cactus', 'cadena', 'cafe', 'caja', 'calabaza', 'caldo', 'camino', 'campana',
    'canasta', 'cangrejo', 'canoa', 'cantera', 'caramelo', 'carbon', 'carpa', 'cascada', 'castillo', 'cebada',
    'cedro', 'cemento', 'cepillo', 'cereza', 'cielo', 'cinta', 'ciruela', 'ciudad', 'clavo', 'cobre',
    'cocina', 'cometa', 'conejo', 'copa', 'coral', 'corcho', 'cordel', 'corona', 'cuchara', 'cuerda',
    'cuervo', 'dado', 'delfin', 'desierto', 'diamante', 'dibujo', 'duende', 'dulce', 'duna', 'eco',
    'elefante', 'enebro', 'escoba', 'escudo', 'espejo', 'espiga', 'espuma', 'estanque', 'estrella', 'fabrica',
    'falda', 'farol', 'fideo', 'fiesta', 'flauta', 'flecha', 'foca', 'fogata', 'fresa', 'frijol',
    'fruta', 'fuego', 'fuente', 'gaita', 'galleta', 'ganso', 'garra', 'gaviota', 'gema', 'girasol',
    'globo', 'golfo', 'gorra', 'grano', 'granja', 'grillo', 'gruta', 'guante', 'guitarra', 'hacha',
    'halcon', 'harina', 'helado', 'helecho', 'hielo', 'hierro', 'higo', 'hilo', 'hoja', 'hongo',
    'horno', 'hueso', 'huerta', 'humo', 'iglesia', 'iman', 'invierno', 'isla', 'jabon', 'jardin',
    'jarra', 'jaula', 'jazmin', 'jirafa', 'jugo', 'junco', 'laberinto', 'ladrillo', 'lago', 'lampara',
    'lana', 'lanza', 'lapiz', 'laurel', 'leche', 'lena', 'leon', 'libro', 'lima', 'limon',
    'linterna', 'lirio', 'llave', 'lluvia', 'lobo', 'loma', 'luna', 'lupa', 'madera', 'maiz',
    'malta', 'mango', 'manta', 'manzana', 'mapa', 'marfil', 'mariposa', 'martillo', 'mecha', 'medalla',
    'melon', 'menta', 'mesa', 'miel', 'mirlo', 'molino', 'moneda', 'montana', 'morsa', 'mosaico',
    'motor', 'muelle', 'musgo', 'nabo', 'naranja', 'nave', 'nido', 'niebla', 'nieve', 'nube',
    'nudo', 'nuez', 'oasis', 'olivo', 'olla', 'onda', 'oro', 'ortiga', 'oso', 'ostra',
    'otono', 'oveja', 'pajaro', 'pala', 'palma', 'paloma', 'panal', 'pantano', 'papel', 'parra',
    'pasto', 'pato', 'pecera', 'pelota', 'pera', 'perla', 'pescado', 'pincel', 'pino', 'pizarra',
    'plata', 'playa', 'pluma', 'polen', 'pozo', 'pradera', 'puente', 'puerta', 'pulpo', 'queso',
    'quinoa', 'rama', 'rana', 'rayo', 'reloj', 'remo', 'represa', 'risco', 'roble', 'roca',
    'rocio', 'romero', 'rueda', 'sal', 'salmon', 'sauce', 'selva', 'semilla', 'senda', 'sierra',
    'silla', 'sirena', 'sombra', 'sonrisa', 'sopa', 'surco', 'tabla', 'taller', 'tambor', 'tapiz',
    'tarta', 'taza', 'techo', 'tejado', 'telar', 'templo', 'tienda', 'tierra', 'tigre', 'tinta',
    'topacio', 'tormenta', 'torre', 'tortuga', 'trebol', 'trigo', 'trineo', 'trueno', 'tulipan', 'tunel',
    'valle', 'vapor', 'vela', 'venado', 'ventana', 'verano', 'vidrio', 'viento', 'vino', 'violeta'
)

function Get-ZsWordList {
    <#
        .SYNOPSIS
        Devuelve la lista de palabras usada para generar contrasenas.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return $script:ZsWords
}

function Get-ZsRandomPassword {
    <#
        .SYNOPSIS
        Contrasena legible de tres palabras y cuatro digitos: "arena-tulipan-molino-4821".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # RandomNumberGenerator y no Get-Random: el valor termina en el .env de alguien.
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $picked = @()
        for ($i = 0; $i -lt 3; $i++) {
            $picked += $script:ZsWords[(Get-ZsRandomNumber -Rng $rng -Maximum $script:ZsWords.Count)]
        }
        $digits = Get-ZsRandomNumber -Rng $rng -Maximum 10000
        return ('{0}-{1:d4}' -f ($picked -join '-'), $digits)
    }
    finally {
        $rng.Dispose()
    }
}

function Get-ZsRandomNumber {
    <#
        .SYNOPSIS
        Entero uniforme en [0, Maximum) sacado del generador criptografico.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [System.Security.Cryptography.RandomNumberGenerator]$Rng,

        [Parameter(Mandatory)]
        [int]$Maximum
    )

    # Rechazo por muestreo: sin el, los primeros valores del rango salen mas seguido.
    $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$Maximum) - 1
    $buffer = New-Object byte[] 4
    while ($true) {
        $Rng.GetBytes($buffer)
        $value = [System.BitConverter]::ToUInt32($buffer, 0)
        if ($value -le $limit) {
            return [int]($value % [uint32]$Maximum)
        }
    }
}

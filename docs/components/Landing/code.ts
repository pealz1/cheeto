export type Token = { text: string; kind?: string }

export type Sample = {
  file: string
  language: 'cheeto' | 'luau'
  source: string
}

export const SAMPLES: Sample[] = [
  {
    file: 'network.cheeto',
    language: 'cheeto',
    source: `option ClientOutput = "Network/Client.luau"
option ServerOutput = "Network/Server.luau"
option SecurityPreset = Maximum

struct Hit {
    Target: Instance(Player),
    Damage: u16(0..500)
}

event DealDamage {
    From: Client,
    Type: Reliable,
    Call: SingleAsync,
    Policy: "damage",
    CooldownSeconds: 0.25,
    Data: Hit
}

event Announce {
    From: Server,
    Type: Reliable,
    Call: ManyAsync,
    Data: string(0..128)
}`
  },
  {
    file: 'Server.server.luau',
    language: 'luau',
    source: `local Network = require(ReplicatedStorage.Network.Server)

-- Runs before the payload is even decoded
Network.Security.RegisterPolicy("damage", function(context)
    local character = context.Source.Character
    return character ~= nil, "no-character"
end)

Network.DealDamage.On(function(player, hit)
    Combat.Apply(player, hit.Target, hit.Damage)
end)

Network.Announce.FireAll("Round starting!")`
  },
  {
    file: 'Client.client.luau',
    language: 'luau',
    source: `local Network = require(ReplicatedStorage.Network.Client)

Network.Announce.On(function(message)
    Toast.Show(message)
end)

Sword.Activated:Connect(function()
    -- Fully typed: { Target: Player, Damage: number }
    Network.DealDamage.Fire({ Target = target, Damage = 25 })
end)`
  }
]

const KEYWORDS: Record<Sample['language'], RegExp> = {
  cheeto:
    /^(?:option|struct|event|function|type|enum|map|set|import|export|scope|channel)\b/,
  luau: /^(?:local|function|return|end|if|then|else|elseif|not|and|or|nil|true|false|for|in|do|while)\b/
}

const TYPES =
  /^(?:u8|u16|u32|i8|i16|i32|f16|f32|f64|string|boolean|buffer|vector|unknown|Instance|CFrame|Color3|Vector3|Vector2|Player)\b/

const RULES: Array<[RegExp, string]> = [
  [/^--[^\n]*/, 'comment'],
  [/^"[^"\n]*"/, 'string'],
  [/^\d+(?:\.\d+)?(?:\.\.\d+)?/, 'number'],
  [/^\.\./, 'operator'],
  [/^[A-Za-z_][A-Za-z0-9_]*(?=\s*\()/, 'call'],
  [/^[A-Za-z_][A-Za-z0-9_]*(?=\s*:(?!\w*\())/, 'property'],
  [/^[A-Za-z_][A-Za-z0-9_]*/, 'identifier'],
  [/^\s+/, 'space'],
  [/^[{}()[\],.:=]/, 'punctuation'],
  [/^./, 'text']
]

export function tokenize(source: string, language: Sample['language']): Token[][] {
  return source.split('\n').map((line) => {
    const tokens: Token[] = []
    let rest = line
    while (rest.length > 0) {
      const keyword = rest.match(KEYWORDS[language])
      const type = rest.match(TYPES)
      if (keyword) {
        tokens.push({ text: keyword[0], kind: 'keyword' })
        rest = rest.slice(keyword[0].length)
        continue
      }
      if (type) {
        tokens.push({ text: type[0], kind: 'type' })
        rest = rest.slice(type[0].length)
        continue
      }
      for (const [pattern, kind] of RULES) {
        const match = rest.match(pattern)
        if (match) {
          const previous = tokens[tokens.length - 1]
          const resolved =
            kind === 'identifier' && /^[A-Z]/.test(match[0]) && language === 'cheeto'
              ? 'constant'
              : kind === 'identifier' && previous?.text === '.'
                ? 'member'
                : kind
          tokens.push({ text: match[0], kind: resolved })
          rest = rest.slice(match[0].length)
          break
        }
      }
    }
    return tokens
  })
}

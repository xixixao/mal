namespace Mal;

type Token = string;

function read_str(string $mal_code): Form {
  $tokens = tokenize($mal_code);
  if (C\is_empty($tokens)) {
    return new GlobalNil();
  }
  list($ast, $_reader) = read_form(new Reader($tokens));
  return $ast;
}

final class Reader {
  public function __construct(
    private vec<Token> $tokens,
    private int $index = 0,
  ) {}

  public function peek(): ?Token {
    return idx($this->tokens, $this->index);
  }

  public function peekx(string $error_message): Token {
    $token = $this->peek();
    if ($token is null) {
      throw $this->exception($error_message);
    }
    return $token as nonnull;
  }

  public function next(): Reader {
    return new Reader($this->tokens, $this->index + 1);
  }

  public function exception(string $error_message): ReaderException {
    return new ReaderException($error_message, $this->index);
  }
}

function tokenize(string $mal_code): vec<Token> {
  $matches = Regex\every_match(
    $mal_code,
    // Matches all mal tokens
    re"/[\s,]*(~@|[\[\]{}()'`~^@]|\"(?:\\\\.|[^\\\\\"])*\"?|;.*|[^\s\[\]{}('\"`,;)]*)/",
  );
  return $matches
    |> Vec\map($$, $match ==> $match[1])
    |> Vec\filter($$, $token ==> !Str\is_empty($token))
    |> Vec\filter($$, $token ==> !Str\starts_with($token, ';'));
}

function read_form(Reader $token_reader): (Form, Reader) {
  return read_list($token_reader) ??
    read_vector($token_reader) ??
    read_hash_map($token_reader) ??
    read_deref($token_reader) ??
    read_quote($token_reader) ??
    read_quasiquote($token_reader) ??
    read_unquote($token_reader) ??
    read_splice_unquote($token_reader) ??
    read_with_meta($token_reader) ??
    read_atom($token_reader);
}

function read_list(Reader $token_reader): ?(ListForm, Reader) {
  return read_children_form(
    $token_reader,
    '(',
    ')',
    ($children, $_) ==> new ListForm($children),
  );
}

function read_vector(Reader $token_reader): ?(VectorForm, Reader) {
  return read_children_form(
    $token_reader,
    '[',
    ']',
    ($children, $_) ==> new VectorForm($children),
  );
}

function read_hash_map(Reader $token_reader): ?(HashMapForm, Reader) {
  return read_children_form(
    $token_reader,
    '{',
    '}',
    ($children, $token_reader) ==> pairs_to_map(read_pairs(
      $children,
      $key ==> {
        if (!$key is Key) {
          throw $token_reader->exception(
            "Expected a key atom, got `".pr_str($key)."`",
          );
        }
        return $key;
      },
      $key ==> $token_reader->exception(
        "Expected a value atom for key `".pr_str($key, true)."`",
      ),
    )),
  );
}

function read_children_form<TForm>(
  Reader $token_reader,
  Token $start_token,
  Token $end_token,
  (function(vec<Form>, Reader): TForm) $create_node,
): ?(TForm, Reader) {
  $first_token = $token_reader->peekx(
    'Unexpected end of input, expected a form',
  );
  if ($first_token !== $start_token) {
    return null;
  }
  $children = vec[];
  while (true) {
    $token_reader = $token_reader->next();
    $next_token = $token_reader->peekx(
      "Unexpected unbalanced $start_token, expected a form or `$end_token`",
    );
    if ($next_token === $end_token) {
      return tuple($create_node($children, $token_reader), $token_reader);
    } else {
      list($child, $token_reader) = read_form($token_reader);
      $children[] = $child;
    }
  }
}

function read_deref(Reader $token_reader): ?(ListForm, Reader) {
  return read_macro('@', 'deref', $token_reader);
}

function read_quote(Reader $token_reader): ?(ListForm, Reader) {
  return read_macro("'", 'quote', $token_reader);
}

function read_quasiquote(Reader $token_reader): ?(ListForm, Reader) {
  return read_macro("`", 'quasiquote', $token_reader);
}

function read_unquote(Reader $token_reader): ?(ListForm, Reader) {
  return read_macro("~", 'unquote', $token_reader);
}

function read_splice_unquote(Reader $token_reader): ?(ListForm, Reader) {
  return read_macro("~@", 'splice-unquote', $token_reader);
}

function read_with_meta(Reader $token_reader): ?(ListForm, Reader) {
  $reader_name = "^";
  $eval_name = 'with-meta';
  $first_token = $token_reader->peekx(
    'Unexpected end of input, expected a form',
  );
  if ($first_token !== $reader_name) {
    return null;
  }
  $token_reader = $token_reader->next();
  $token_reader->peekx("Expected a form following ".$reader_name);
  list($metadata, $token_reader) = read_form($token_reader);
  $token_reader = $token_reader->next();
  $token_reader->peekx("Expected a second form following ".$reader_name);
  list($function, $token_reader) = read_form($token_reader);
  return tuple(
    new_function_call($eval_name, vec[$function, $metadata]),
    $token_reader,
  );
}

function read_macro(
  string $reader_name,
  string $eval_name,
  Reader $token_reader,
): ?(ListForm, Reader) {
  $first_token = $token_reader->peekx(
    'Unexpected end of input, expected a form',
  );
  if ($first_token !== $reader_name) {
    return null;
  }
  $token_reader = $token_reader->next();
  $token_reader->peekx("Expected a form following ".$reader_name);
  list($argument, $token_reader) = read_form($token_reader);
  return tuple(new_function_call($eval_name, vec[$argument]), $token_reader);
}

function read_atom(Reader $token_reader): (Atom, Reader) {
  $token = $token_reader->peekx('Expected an atom');
  return tuple(atom_node($token, $token_reader), $token_reader);
}

function atom_node(string $token, Reader $token_reader): Atom {
  if (Regex\matches($token, re"/^-?\d/")) {
    return new Number((int)$token);
  } else if (Str\starts_with($token, ':')) {
    return new Keyword(Str\slice($token, 1));
  } else if (Str\starts_with($token, '"')) {
    if (!Regex\matches($token, re"/^\"(?:\\\\.|[^\\\\\"])*\"$/")) {
      throw $token_reader->exception('Unexpected end of input, expected `"`');
    }
    return new StringAtom(read_string($token));
  } else if ($token === 'nil') {
    return new GlobalNil();
  } else if ($token === 'false') {
    return new BoolAtom(false);
  } else if ($token === 'true') {
    return new BoolAtom(true);
  } else {
    return new Symbol($token);
  }
}

function read_string(string $code_string): string {
  return $code_string
    |> Str\slice($$, 1, Str\length($code_string) - 2)
    |> Regex\replace_with($$, re"/\\\\\\\\|\\\\n|\\\\\"/", $match ==> {
      switch ($match[0]) {
        case '\\\\':
          return '\\';
        case '\n':
          return "\n";
        case '\"':
        default: // exhaustive
          return "\"";
      }
    });
}

function read_pairs<TKey>(
  vec<Form> $list,
  (function(Form): TKey) $check_key,
  (function(TKey): \Throwable) $get_uneven_exception,
): vec<(TKey, Form)> {
  $num_items = C\count($list);
  $pairs = vec[];
  for ($i = 0; $i < $num_items; $i += 2) {
    $key = $check_key($list[$i]);
    if ($i + 1 >= $num_items) {
      throw $get_uneven_exception($key);
    }
    $pairs[] = tuple($key, $list[$i + 1]);
  }
  return $pairs;
}

function pairs_to_map(vec<(Key, Form)> $children_pairs): HashMapForm {
  $map = dict[];
  foreach ($children_pairs as $key_value_pair) {
    list($key, $value) = $key_value_pair;
    $map[key_to_string($key)] = $value;
  }
  return new HashMapForm($map);
}

function children_pairs(HashMapForm $form): vec<(Key, Form)> {
  $pairs = vec[];
  foreach ($form->map as $key => $value) {
    $pairs[] = tuple(string_to_key($key), $value);
  }
  return $pairs;
}

function key_to_string(Key $key): string {
  if ($key is Keyword) {
    return "\u{29e}".$key->name;
  }
  if ($key is StringAtom) {
    return $key->value;
  }
  invariant(false, 'Unsupported Key subtype');
}

function string_to_key(string $key): Key {
  if (Str\starts_with($key, "\u{29e}")) {
    return new Keyword(Str\slice($key, 2));
  }
  return new StringAtom($key);
}

import 'dart:convert';

import 'package:dotenv/dotenv.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

// Middleware CORS para permitir requisições de qualquer origem
Middleware corsHeaders() {
  return (Handler handler) {
    return (Request request) async {
      // Se for uma requisição OPTIONS (preflight), responde imediatamente
      if (request.method == 'OPTIONS') {
        return Response.ok(
          '',
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
            'Access-Control-Allow-Headers':
                'Origin, Content-Type, Accept, Authorization',
            'Access-Control-Max-Age': '86400',
          },
        );
      }

      // Para outras requisições, adiciona headers CORS na resposta
      final response = await handler(request);
      return response.change(
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'Access-Control-Allow-Headers':
              'Origin, Content-Type, Accept, Authorization',
        },
      );
    };
  };
}

void main() async {
  try {
    // Carregar variáveis de ambiente
    final env = DotEnv(includePlatformEnvironment: true)..load();

    final conn = await Connection.open(
      Endpoint(
        host: env['DB_HOST']!,
        port: int.parse(env['DB_PORT']!),
        database: env['DB_NAME']!,
        username: env['DB_USER'],
        password: env['DB_PASSWORD'],
      ),
      settings: const ConnectionSettings(
        sslMode: SslMode.disable, // ou SslMode.require, etc.
      ),
    );

    print('Conectado ao PostgreSQL!');

    // Criar tabelas (se não existirem)
    await conn.execute('''
    CREATE TABLE IF NOT EXISTS usuarios (
      id SERIAL PRIMARY KEY,
      nome VARCHAR(100) NOT NULL,
      email VARCHAR(100) UNIQUE NOT NULL,
      senha VARCHAR(255) NOT NULL,
      data_criacao TIMESTAMP DEFAULT NOW()
    );
  ''');

    await conn.execute('''
    CREATE TABLE IF NOT EXISTS logs (
      id SERIAL PRIMARY KEY,
      usuario_id INTEGER REFERENCES usuarios(id),
      acao VARCHAR(50) NOT NULL,
      descricao TEXT,
      tabela VARCHAR(50),
      registro_id INTEGER,
      data_hora TIMESTAMP DEFAULT NOW()
    );
  ''');

    await conn.execute('''
    CREATE TABLE IF NOT EXISTS cotacoes (
      id SERIAL PRIMARY KEY,
      moeda VARCHAR(10) NOT NULL,
      valor DECIMAL(10, 4) NOT NULL,
      usuario_id INTEGER REFERENCES usuarios(id),
      data_cotacao TIMESTAMP DEFAULT NOW()
    );
  ''');

    print('✅ Tabelas criadas/verificadas!');

    final router = Router();

    // ========== ENDPOINTS DE AUTENTICAÇÃO ==========

    // Registro de novo usuário
    router.post('/auth/register', (Request req) async {
      try {
        final body = await req.readAsString();
        final json = jsonDecode(body);
        final nome = json['nome'];
        final email = json['email'];
        final senha = json['senha'];

        // Verificar se email já existe
        final existe = await conn.execute(
          r'SELECT id FROM usuarios WHERE email = $1',
          parameters: [email],
        );

        if (existe.isNotEmpty) {
          return Response(
            409,
            body: jsonEncode({'error': 'Email já cadastrado'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        // Inserir novo usuário (em produção, use hash para senha!)
        final result = await conn.execute(
          r'INSERT INTO usuarios (nome, email, senha) VALUES ($1, $2, $3) RETURNING id, nome, email',
          parameters: [nome, email, senha],
        );

        final row = result.first.toList();
        final usuario = {'id': row[0], 'nome': row[1], 'email': row[2]};

        // Registrar log
        await conn.execute(
          r'INSERT INTO logs (usuario_id, acao, descricao) VALUES ($1, $2, $3)',
          parameters: [row[0], 'REGISTRO', 'Novo usuário registrado: $nome'],
        );

        print('✅ Usuário registrado: $nome');
        return Response.ok(
          jsonEncode(usuario),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e, stack) {
        print('❌ Erro no registro: $e');
        print('Stack: $stack');
        return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // Login de usuário
    router.post('/auth/login', (Request req) async {
      try {
        final body = await req.readAsString();
        final json = jsonDecode(body);
        final email = json['email'];
        final senha = json['senha'];

        final result = await conn.execute(
          r'SELECT id, nome, email FROM usuarios WHERE email = $1 AND senha = $2',
          parameters: [email, senha],
        );

        if (result.isEmpty) {
          return Response(
            401,
            body: jsonEncode({'error': 'Email ou senha incorretos'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        final row = result.first.toList();
        final usuario = {'id': row[0], 'nome': row[1], 'email': row[2]};

        // Registrar log
        await conn.execute(
          r'INSERT INTO logs (usuario_id, acao, descricao) VALUES ($1, $2, $3)',
          parameters: [row[0], 'LOGIN', 'Usuário ${row[1]} fez login'],
        );

        print('✅ Login bem-sucedido: ${row[1]}');
        return Response.ok(
          jsonEncode(usuario),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e, stack) {
        print('❌ Erro no login: $e');
        print('Stack: $stack');
        return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // Buscar logs
    router.get('/logs', (Request req) async {
      try {
        final results = await conn.execute('''
          SELECT l.id, l.acao, l.descricao, l.tabela, l.registro_id, l.data_hora, u.nome
          FROM logs l
          LEFT JOIN usuarios u ON l.usuario_id = u.id
          ORDER BY l.data_hora DESC
          LIMIT 100
        ''');

        final logs = results.map((row) {
          final rowList = row.toList();
          return {
            'id': rowList[0],
            'acao': rowList[1],
            'descricao': rowList[2],
            'tabela': rowList[3],
            'registro_id': rowList[4],
            'data_hora': (rowList[5] as DateTime).toIso8601String(),
            'usuario_nome': rowList[6],
          };
        }).toList();

        return Response.ok(
          jsonEncode(logs),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        print('❌ Erro ao buscar logs: $e');
        return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    // ========== ENDPOINTS DE COTAÇÕES ==========

    router.get('/cotacoes', (Request req) async {
      try {
        print('Buscando cotações...');
        final results = await conn.execute(
          'SELECT id, moeda, valor, usuario_id, data_cotacao FROM cotacoes ORDER BY id DESC',
        );
        print('Encontradas ${results.length} cotações');

        final cotacoes = results.map((row) {
          try {
            final rowAsList = row.toList();
            print('Processando linha: $rowAsList');

            // Converte o valor para string de forma segura
            final valor = rowAsList[2];
            final valorString = valor.toString();

            return {
              'id': rowAsList[0],
              'moeda': rowAsList[1],
              'valor': valorString,
              'usuario_id': rowAsList[3],
              'data_cotacao': rowAsList[4] != null
                  ? (rowAsList[4] as DateTime).toIso8601String()
                  : null,
            };
          } catch (e) {
            print('Erro ao processar linha: $e');
            rethrow;
          }
        }).toList();

        print('Cotações processadas: $cotacoes');
        return Response.ok(
          jsonEncode(cotacoes),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e, stack) {
        print('Erro ao buscar cotações: $e');
        print('Stack: $stack');
        return Response.internalServerError(
          body: jsonEncode({'error': e.toString(), 'stack': stack.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });
    router.post('/cotacoes', (Request req) async {
      try {
        final body = await req.readAsString();
        final json = jsonDecode(body);
        final moeda = json['moeda'];
        final valor = json['valor'];
        final usuarioId = json['usuario_id']; // ID do usuário logado

        final result = await conn.execute(
          r'INSERT INTO cotacoes (moeda, valor, usuario_id) VALUES ($1, $2, $3) RETURNING id',
          parameters: [moeda, valor, usuarioId],
        );

        final cotacaoId = result.first.toList()[0];

        // Registrar log
        await conn.execute(
          r'INSERT INTO logs (usuario_id, acao, descricao, tabela, registro_id) VALUES ($1, $2, $3, $4, $5)',
          parameters: [
            usuarioId,
            'CREATE',
            'Cotação criada: $moeda - $valor',
            'cotacoes',
            cotacaoId,
          ],
        );

        print('✅ Cotação criada: $moeda - $valor');
        return Response.ok(
          '{"status": "sucesso", "id": $cotacaoId}',
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        print('❌ Erro ao criar cotação: $e');
        return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    router.put('/cotacoes/<id>', (Request req, String id) async {
      try {
        final body = await req.readAsString();
        final json = jsonDecode(body);
        final moeda = json['moeda'];
        final valor = json['valor'];
        final usuarioId = json['usuario_id'];

        await conn.execute(
          r'UPDATE cotacoes SET moeda = $1, valor = $2 WHERE id = $3',
          parameters: [moeda, valor, int.parse(id)],
        );

        // Registrar log
        await conn.execute(
          r'INSERT INTO logs (usuario_id, acao, descricao, tabela, registro_id) VALUES ($1, $2, $3, $4, $5)',
          parameters: [
            usuarioId,
            'UPDATE',
            'Cotação atualizada: $moeda - $valor',
            'cotacoes',
            int.parse(id),
          ],
        );

        print('✅ Cotação atualizada: ID $id');
        return Response.ok(
          '{"status": "atualizado"}',
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        print('❌ Erro ao atualizar cotação: $e');
        return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    router.delete('/cotacoes/<id>', (Request req, String id) async {
      try {
        // Buscar info da cotação antes de deletar
        final cotacao = await conn.execute(
          r'SELECT moeda, valor FROM cotacoes WHERE id = $1',
          parameters: [int.parse(id)],
        );

        String descricao = 'Cotação deletada';
        if (cotacao.isNotEmpty) {
          final row = cotacao.first.toList();
          descricao = 'Cotação deletada: ${row[0]} - ${row[1]}';
        }

        await conn.execute(
          r'DELETE FROM cotacoes WHERE id = $1',
          parameters: [int.parse(id)],
        );

        // Tentar pegar usuario_id do body (se enviado)
        int? usuarioId;
        try {
          final body = await req.readAsString();
          if (body.isNotEmpty) {
            final json = jsonDecode(body);
            usuarioId = json['usuario_id'];
          }
        } catch (_) {}

        // Registrar log
        if (usuarioId != null) {
          await conn.execute(
            r'INSERT INTO logs (usuario_id, acao, descricao, tabela, registro_id) VALUES ($1, $2, $3, $4, $5)',
            parameters: [
              usuarioId,
              'DELETE',
              descricao,
              'cotacoes',
              int.parse(id),
            ],
          );
        }

        print('✅ Cotação deletada: ID $id');
        return Response.ok(
          '{"status": "deletado"}',
          headers: {'Content-Type': 'application/json'},
        );
      } catch (e) {
        print('❌ Erro ao deletar cotação: $e');
        return Response.internalServerError(
          body: jsonEncode({'error': e.toString()}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    });

    final handler = Pipeline()
        .addMiddleware(corsHeaders())
        .addMiddleware(logRequests())
        .addHandler(router);

    // Porta do servidor (usa PORT do ambiente ou 8080 como padrão)
    final port = int.parse(env['PORT'] ?? '8080');

    // Escuta em TODAS as interfaces (0.0.0.0)
    final server = await io.serve(handler, '0.0.0.0', port);
    print('🚀 Servidor rodando em http://0.0.0.0:${server.port}');
    print('✅ CORS habilitado para requisições externas');
  } catch (e, stack) {
    print('Erro fatal no servidor: $e');
    print('Stack: $stack');
  }
}

import 'dart:convert';
import 'package:dotenv/dotenv.dart';
import 'package:postgres/postgres.dart';

void main() async {
  try {
    final env = DotEnv(includePlatformEnvironment: true)..load();

    final conn = await Connection.open(
      Endpoint(
        host: env['DB_HOST']!,
        port: int.parse(env['DB_PORT']!),
        database: env['DB_NAME']!,
        username: env['DB_USER'],
        password: env['DB_PASSWORD'],
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

    print('✅ Conectado ao PostgreSQL!');

    // Testar SELECT
    print('\n📊 Buscando cotações...');
    final results = await conn.execute(
      'SELECT id, moeda, valor FROM cotacoes ORDER BY id DESC',
    );

    print('Encontradas ${results.length} cotações\n');

    for (var row in results) {
      final rowList = row.toList();
      print(
        'ID: ${rowList[0]}, Moeda: ${rowList[1]}, Valor: ${rowList[2]} (${rowList[2].runtimeType})',
      );

      final cotacao = {
        'id': rowList[0],
        'moeda': rowList[1],
        'valor': rowList[2].toString(),
      };
      print('JSON: ${jsonEncode(cotacao)}\n');
    }

    await conn.close();
    print('✅ Teste concluído!');
  } catch (e, stack) {
    print('❌ Erro: $e');
    print('Stack: $stack');
  }
}

# Deploy Backend - Render.com

## URL do seu app após deploy:
https://seu-app.onrender.com

## Variáveis de Ambiente a configurar no Render:

```
DB_HOST=seu-postgres-host.render.com
DB_PORT=5432
DB_NAME=cotacao_db
DB_USER=seu_usuario
DB_PASSWORD=sua_senha
```

## Instruções:

1. Acesse: https://render.com
2. Faça cadastro/login
3. Clique em "New +" → "Web Service"
4. Conecte seu GitHub ou faça upload
5. Configure:
   - Name: cotacao-backend
   - Environment: Dart
   - Build Command: dart pub get
   - Start Command: dart run bin/server.dart
6. Adicione as variáveis de ambiente
7. Clique em "Create Web Service"
8. Aguarde o deploy (~3-5 minutos)
9. Copie a URL gerada
10. Atualize lib/src/services/api_service.dart com a nova URL
11. Refaça o build: flutter build web --release
12. Faça novo deploy no Netlify

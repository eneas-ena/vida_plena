# VidaPlena

Painel pessoal de produtividade e ministério: mural, tarefas, agenda, devocional, clima, cotação do dólar e sugestões por IA.

**Abrir o app:** https://eneas-ena.github.io/vida_plena/

## Como funciona

- App feito em página web; pode ser instalado na tela inicial do iPad, iPhone ou Mac.
- Os dados ficam salvos no Supabase, por isso aparecem iguais em todos os aparelhos.
- Os serviços externos, como a inteligência artificial, passam pelos Workers `promptflow-ia` e `vidaplena-bolsa` no Cloudflare; as chaves secretas ficam guardadas lá, nunca neste código.

## Observações

- `backup-instalar.sh` instala no Mac o motor de backup automático.
- `testes.html` é uma página de testes, não faz parte do app.
- O arquivo `Ícone Premium Vida Plena.png` é o original do ícone; o app usa `icon-192.png` e `icon-512.png`.

## Como publicar uma nova versão

1. Nesta página do repositório, clique em **Add file → Upload files**.
2. Arraste os arquivos novos, com os mesmos nomes dos antigos.
3. Clique em **Commit changes**.

Em um ou dois minutos a nova versão está no ar no mesmo endereço.

---
Desenvolvido por Bispo Enéas Araújo.

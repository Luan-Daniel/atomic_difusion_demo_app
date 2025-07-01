= Anotações =

Implementar aplicação simples pro trabalho de SD:
- Aplicação da opção de cliente/servidor e grupo.
- Servidores iniciam o grupo.
  + O primeiro servidor não encontrar o grupo (busca de serviço falha), e inicia o grupo.
  + Os proximos servidores encontram o grupo e zeram o estado.
- Clientes entram no grupo e fazem difusão atomica de mensagens para os servidores.
  + Mensagem gerada aleatoriamente
  + Usam arquitetura Anel lógico com token virtual (privilegio).
- Servidores salvam a mensagem.
  + Para simplicidade, sevidorem sempre começam sem memoria.
- (Opcional) Implementar algoritmos de eleição em anel para aparar perda de token.
  + Fazer implementação simples.
- (Opcional) Fazer implementação simples de replicação de estado.


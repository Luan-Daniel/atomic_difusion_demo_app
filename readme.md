# Implementação de Difusão Atômica Baseada em Privilégio em Godot 4

## 1. Proposta do Trabalho

Este projeto demonstra um protocolo de difusão atômica (total order broadcast) baseado em privilégio, onde emissores formam um anel lógico e circulam um token de prioridade. Cada emissor só difunde suas mensagens ao grupo de receptores enquanto detém o token, garantindo exclusão mútua no envio e ordem total de entrega. O sistema usa Godot 4, multicast UDP e uma interface gráfica para gerar e pintar pixels com cores e posições variadas.


## 2. Requisitos Funcionais

### 2.1 Emissor (Cliente)

- **Identificação**
  Cada nó emissor possui um `node_id` único, gerado a partir de timestamp + aleatório ou carregado de disco.
- **Geração de Mensagens**
  A cada 0,5 s, gera um pixel contendo coordenadas e cor RGB, e o enfileira em `pending_msgs`.
- **Token e Privilégio**
  - Junta‐se ao grupo de emissores via multicast UDP (`JOIN_REQ` / `JOIN_ACK`).
  - Apenas difunde quando `have_token == true`.
  - Após difundir todos os `pending_msgs`, passa o token ao successor.
- **Formato de Mensagem**
  JSON: `{"seq": <int>, "payload": {"pos":<int>, "color":[r,g,b]}, "ts": <int>}`.

### 2.2 Receptor (Servidor)

- **Identificação**
  Usa IP/porta apenas para log; não há election nem token.
- **Recepção de Mensagens**
  Ingere pacotes JSON do grupo de receptores multicast:
  ```json
  { "seq":42, "payload" {"pos":11, "color":[255,0,0]}, "ts":999}
  ```
- **Ordenação e Buffer**
  - Armazena fora de ordem em `holdback_buffer[seq]`.
  - Entrega em ordem crescente, começando em `next_expected_seq = 1`.
- **Tratamento de Falhas UDP**
  Pixels perdidos são simplesmente sobrescritos no futuro, garantindo que versões antigas não voltem.

## 3. Comunicação Cliente-Servidor

### 3.1 Grupos Multicast

1. **Grupo de Emissores** (`egroup_ip:9321`)
   - Contém mensagens de controle:
     - JOIN_REQ / JOIN_ACK / MEMBERSHIP
     - PING / PONG (heartbeat)
     - TOKEN / TOKEN_ACK

2. **Grupo de Receptores** (`rgroup_ip:9321`)
   - Recebe difusão de dados: JSON `{seq, payload, ts}`.

### 3.2 Diagrama de Sequência

[A FAZER]

## 4. Serviço no Servidor de Receptores

No script **Receptor.gd**, o servidor:

1. **Entrar no Grupo**
   ```gdscript
   group_mngr = MulticastGroup.new(rgroup_ip, 9321, network_interface)
   group_mngr.join_group()
   ```

2. **Receber Mensagens**
   ```gdscript
   func _on_message_received(message, sender_ip, port):
       var data = JSON.parse(message.get_string_from_utf8()).get_data()
       var seq = data["seq"]
       var payload = data["payload"]
       # buffer ou entrega imediatamente...
   ```

3. **Buffer Holdback e Entrega Ordenada**
   ```gdscript
   if seq == next_expected_seq:
       handle_payload(payload)
       next_expected_seq += 1
       # limpa buffer em sequência
   elif seq > next_expected_seq:
       holdback_buffer[seq] = payload
   ```

4. **Timer de Limpeza Periódica**
   ```gdscript
   holdback_timer.wait_time = 2.0
   holdback_timer.start()
   holdback_timer.timeout.connect(_on_holdback_timer)
   ```

5. **Consome Mensagens ordenadas**


## 5. Exemplos de Blocos de Código

### 5.1 Emissor: Envio de Token e Dados

```gdscript
func _deliver_pending():
    for msg in pending_msgs:
        global_seq += 1
        var packet = { "seq":global_seq, "payload":msg }
        var buf = JSON.stringify(packet).to_utf8_buffer()
        group_mngr.send_message(buf, rgroup_ip, PORT)
    pending_msgs.clear()
    _pass_token()
```

### 5.2 Emissor: Passagem de Token

```gdscript
func _pass_token():
    var body = { "token_id":token_id, "sequence":global_seq, "from_id":node_id }
    var buf = JSON.stringify({"type":"TOKEN","body":body}).to_utf8_buffer()
    group_mngr.send_message(buf, successor.ip, successor.port)
    have_token = false
```

### 5.3 Receptor: Recepção de Dados

```gdscript
func _on_message_received(message, sender_ip, port):
    var data = JSON.parse(message.get_string_from_utf8()).get_data()
    var seq = data["seq"]
    var payload = data["payload"]
    # ordena e executa handle_payload(payload)
```

---

## 6. Considerações Finais e Próximos Passos

- Testar com perda de pacotes emulações para validar estratégia de sobrescrever pixels.
- Monitorar latência de entrega e circulação do token conforme escala.
- Explorar variações com múltiplos tokens ou subgrupos para paralelismo de difusão.

Para aprofudnar, vale estudar protocolos como SWIM para falhas, Chord para anéis escaláveis e Paxos para ordem forte sem token.
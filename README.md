Inviter Escarlate

Addon para World of Warcraft: Wrath of the Lich King 3.3.5a que organiza convites de dungeon e raid pela guild. Quem digitar @ no chat da guild é convidado automaticamente para o grupo.

Recursos
Auto-invite pelo chat da guild: convida quem mandar @ (em qualquer lugar da frase) ou a palavra-chave configurada. Opcionalmente aceita também por whisper.
Dungeon ou raid: dungeon (5), raid 10 ou raid 25, em normal ou heroico. A dificuldade escolhida é aplicada ao grupo.
Conversão automática para raid: no modo raid, o grupo vira raid assim que a primeira pessoa entra.
Limite de vagas: os convites param quando o grupo atinge o tamanho escolhido e voltam quando alguém sai.
Nível mínimo: só convida personagens de nível 80.
Filtro por função (só dungeon): controla as vagas de tank, healer e DPS.
Mago, bruxo, caçador e ladino entram direto como DPS.
As demais classes usam a função escrita na nota da guild (tank, heal, dps).
Quem não tem função na nota recebe um whisper perguntando a main spec; se aceitar, o addon preenche a nota pública (apenas quando ela está vazia).
A sua própria vaga é descontada pela sua spec atual.
Marcação do tank (só dungeon): coloca o quadrado azul no tank, se ele for da guild.
Anúncios: mensagem padrão com as vagas que faltam, ou um texto customizado. Envio avulso para /g e /5, ou anúncios automáticos em /g a cada 2 minutos, iniciados e parados por um botão.
Localizador de Masmorras: ao entrar na fila, o auto-invite e os anúncios são desligados.
Instalação
Baixe o addon e extraia a pasta InviterEscarlate em World of Warcraft\Interface\AddOns\.
O caminho final deve ser Interface\AddOns\InviterEscarlate\InviterEscarlate.toc.
Reinicie o jogo e confira se Inviter Escarlate está marcado na lista de addons da tela de personagens.
Como usar

Abra as opções com /ie ou em Esc > Interface > AddOns > Inviter Escarlate. São três páginas (clique no + ao lado do nome para ver as duas últimas):

Página	Opções
Inviter Escarlate	Ligar o auto-invite, tipo de grupo, dificuldade, tamanho da raid, palavra-chave e whisper
Funcoes e raids	Filtro de função, vagas de tank/healer/DPS, marcação do tank e as raids citadas na mensagem (EOE, Naxxramas, OS, ICC, TOC, RS)
Anuncios	Mensagem padrão ou customizada, envio para /g e /5 e o botão de anúncios automáticos

Passo a passo básico:

Escolha Dungeon ou Raid, a dificuldade e o tamanho.
Marque Auto-invite ligado.
Na página Anuncios, clique em Enviar /g ou em Iniciar anuncios.
Quem responder com @ no chat da guild é convidado.
Notas da guild

Para o filtro de função em dungeon, escreva a função na nota pública ou na nota de oficial de cada membro: tank, heal ou dps. Para quem faz mais de uma, escreva a principal primeiro, por exemplo tank/dps.

Comandos
Comando	O que faz
/ie	Abre as opções
/ie on e /ie off	Liga e desliga o auto-invite
/ie anuncios	Inicia ou para os anúncios automáticos
/ie status	Mostra o estado atual e por que o addon está (ou não) convidando
/ie spec	Mostra a sua função detectada
/ie spec tank, heal, dps ou auto	Fixa a sua função ou volta à detecção automática
/ie notas	Lista quem pediu alteração de nota da guild
/ie notas limpar	Apaga essa lista

/inviterescarlate e /fi funcionam como atalhos de /ie.

Observações
Você precisa ser o líder do grupo (ou assistente, em raid) para o addon convidar.
O addon ignora o seu próprio personagem: para testar, outra pessoa precisa mandar o @.
O filtro de função, a marcação do tank e o contador de vagas na mensagem valem só para dungeon. Em raid o addon convida todos até o limite, e a composição fica por conta do líder.
Para o addon preencher notas, o seu personagem precisa ter permissão de editar notas públicas na guild.
Em druida feral e cavaleiro da morte a função é estimada pelos atributos; se errar, fixe com /ie spec.
Compatibilidade

Feito para o cliente 3.3.5a (interface 30300). Funciona com a interface padrão do jogo e com ElvUI.

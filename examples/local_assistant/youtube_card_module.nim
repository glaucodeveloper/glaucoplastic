import glaucoplastic

type
  YoutubeCardProps* = object
    title*: string
    href*: string
    channel*: string

glaucoplasticFragment YoutubeCardModule:
  components:
    YoutubeCard(title, href, channel):
      render:
        article CartaoYoutube(
          style = "display:flex;flex-direction:column;gap:8px;padding:14px;border:1px solid rgba(244,244,244,0.10);border-radius:6px;background:#161616"
        ):
          p CartaoYoutubeTag(
            style = "margin:0;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:#c6c6c6"
          ) "Componente modular"

          a CartaoYoutubeLink(
            href = href,
            title = channel,
            style = "color:#78a9ff;text-decoration:none"
          ):
            h3 CartaoYoutubeTitulo(
              style = "margin:0;font-size:16px;line-height:1.4;font-weight:600"
            ) title

          p CartaoYoutubeCanal(
            style = "margin:0;font-size:12px;line-height:1.55;color:#c6c6c6"
          ) channel

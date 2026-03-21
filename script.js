(function ($) {
  function loadNotebook() {
    var hash = location.hash || '#accueil';
    var region = hash.slice(1) + "/" + hash.slice(1);
    var $iframe = $('#content-frame');

    // 1. Set the new source
    $iframe.attr('src', region + '.html');

    // 2. Attach the load listener
    $iframe.off('load').on('load', function() {
      var frame = this;

      // Give Pluto a moment (200ms) to render its initial cells
      setTimeout(function() {
        resizeIframe(frame);
      }, 200);
    });

    // 3. UI Updates
    $('.main-menu a').removeClass('active');
    $('.main-menu a[href="' + hash + '"]').addClass('active');
  }

  function resizeIframe(frame) {
    if (frame && frame.contentWindow) {
      // We force the height to 'auto' first so scrollHeight is accurate
      $(frame).css('height', 'auto');
      var newHeight = frame.contentWindow.document.documentElement.scrollHeight;
      $(frame).css('height', newHeight + 'px');
    }
  }

  $(window).on('resize', function() {
    var frame = document.getElementById('content-frame');
    resizeIframe(frame);
  });

  $(window).on('hashchange', loadNotebook);
  $(document).ready(loadNotebook);
})(jQuery);

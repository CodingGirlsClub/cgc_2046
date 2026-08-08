export default defineAppConfig({
  pages: [
    'pages/discover/index',
    'pages/event-detail/index',
    'pages/register-form/index',
    'pages/my-registrations/index'
  ],
  window: {
    backgroundTextStyle: 'light',
    navigationBarBackgroundColor: '#ffffff',
    navigationBarTitleText: 'CGC',
    navigationBarTextStyle: 'black'
  },
  tabBar: {
    color: '#7a7e83',
    selectedColor: '#07c160',
    backgroundColor: '#ffffff',
    borderStyle: 'black',
    list: [
      {
        pagePath: 'pages/discover/index',
        text: '发现'
      },
      {
        pagePath: 'pages/my-registrations/index',
        text: '我的报名'
      }
    ]
  }
})

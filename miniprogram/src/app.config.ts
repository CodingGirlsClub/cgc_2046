export default defineAppConfig({
  pages: [
    'pages/discover/index',
    'pages/event-detail/index',
    'pages/login/index',
    'pages/register-form/index',
    'pages/enrollment-result/index',
    'pages/my-enrollments/index',
    'pages/workspace/index',
    'pages/profile/index',
    'pages/join/index',
    'pages/openclacky/index'
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
        pagePath: 'pages/my-enrollments/index',
        text: '我的报名'
      },
      {
        pagePath: 'pages/workspace/index',
        text: '工作台'
      },
      {
        pagePath: 'pages/profile/index',
        text: '我的'
      }
    ]
  }
})
